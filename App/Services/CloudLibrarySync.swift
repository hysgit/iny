import Foundation
import CloudKit

actor CloudLibrarySync {
    static let shared = CloudLibrarySync()
    private var operation: Task<LibrarySnapshot, Error>?
    private let database = CKContainer(identifier: "iCloud.net.icycloud.iny").privateCloudDatabase
    func synchronize(_ snapshot: LibrarySnapshot) async throws -> LibrarySnapshot {
        if let operation { return try await operation.value }
        let task = Task { try await run(snapshot) }; operation = task; defer { operation = nil }; return try await task.value
    }
    private func run(_ snapshot: LibrarySnapshot) async throws -> LibrarySnapshot {
        var incoming = LibrarySnapshot()
        var cursor: CKQueryOperation.Cursor?
        repeat {
            let page: (matchResults: [(CKRecord.ID, Result<CKRecord, Error>)], queryCursor: CKQueryOperation.Cursor?)
            if let cursor { page = try await database.records(continuingMatchFrom: cursor, resultsLimit: 200) }
            else { page = try await database.records(matching: CKQuery(recordType: "InyLibrary", predicate: NSPredicate(value: true)), resultsLimit: 200) }
            for (_, result) in page.matchResults {
                let record = try result.get()
                guard let data = record["payload"] as? Data else { continue }
                LibraryMerge.apply(try JSONDecoder().decode(LibrarySnapshot.self, from: data), to: &incoming)
            }
            cursor = page.queryCursor
        } while cursor != nil
        var merged = snapshot; LibraryMerge.apply(incoming, to: &merged)
        var changes: [CKRecord] = []
        for item in merged.items {
            var syncItem = item; syncItem.localFilename = nil; syncItem.subtitleFilename = nil; syncItem.posterFilename = nil
            var payload = LibrarySnapshot(); payload.items = [syncItem]
            let key = item.contentID.map { "content-" + $0 } ?? "item-" + item.id.uuidString
            let record = CKRecord(recordType: "InyLibrary", recordID: CKRecord.ID(recordName: key))
            record["payload"] = try JSONEncoder().encode(payload) as CKRecordValue; changes.append(record)
        }
        for source in merged.sources {
            var payload = LibrarySnapshot(); payload.sources = [source]
            let record = CKRecord(recordType: "InyLibrary", recordID: CKRecord.ID(recordName: "source-" + source.id.uuidString))
            record["payload"] = try JSONEncoder().encode(payload) as CKRecordValue; changes.append(record)
        }
        var tombstones = LibrarySnapshot(); tombstones.deletedItems = merged.deletedItems; tombstones.deletedSources = merged.deletedSources
        let deletion = CKRecord(recordType: "InyLibrary", recordID: CKRecord.ID(recordName: "deletions-" + DeviceIdentity.value))
        deletion["payload"] = try JSONEncoder().encode(tombstones) as CKRecordValue; changes.append(deletion)
        while !changes.isEmpty {
            let batch = Array(changes.prefix(100)); changes.removeFirst(batch.count)
            let result = try await database.modifyRecords(saving: batch, deleting: [], savePolicy: .allKeys, atomically: false)
            for (_, result) in result.saveResults { _ = try result.get() }
        }
        return incoming
    }
}

extension AppStore {
    func synchronizeCloud() async {
        guard UserDefaults.standard.bool(forKey: "cloudLibrarySync"), loaded else { return }
        await perform {
            let incoming = try await CloudLibrarySync.shared.synchronize(library)
            _ = try await repository.mergeCloud(incoming); try await refresh()
        }
    }
}
