import Foundation

enum ContentIdentity {
    static func fingerprint(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let size = try file.seekToEnd(); try file.seek(toOffset: 0)
        var bytes = try file.read(upToCount: 65536) ?? Data()
        if size > 65536 { try file.seek(toOffset: size - 65536); bytes.append(try file.read(upToCount: 65536) ?? Data()) }
        var hash: UInt64 = 14695981039346656037
        for byte in bytes { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return String(size) + "-" + String(hash, radix: 16)
    }
}

enum LibraryMerge {
    static func apply(_ incoming: LibrarySnapshot, to local: inout LibrarySnapshot) {
        var deleted = local.deletedItems ?? [:]; var sourcesDeleted = local.deletedSources ?? [:]
        for (id, date) in incoming.deletedItems ?? [:] { deleted[id] = max(date, deleted[id] ?? .distantPast) }
        for (id, date) in incoming.deletedSources ?? [:] { sourcesDeleted[id] = max(date, sourcesDeleted[id] ?? .distantPast) }
        local.deletedItems = deleted; local.deletedSources = sourcesDeleted
        for source in incoming.sources {
            guard sourcesDeleted[source.id.uuidString] == nil else { continue }
            if let i = local.sources.firstIndex(where: { $0.id == source.id }) {
                if (source.modifiedAt ?? .distantPast) > (local.sources[i].modifiedAt ?? .distantPast) { local.sources[i] = source }
            } else { local.sources.append(source) }
        }
        local.sources.removeAll { sourcesDeleted[$0.id.uuidString] != nil }
        for var item in incoming.items {
            guard deleted[item.id.uuidString] == nil, item.sourceID.map({ sourcesDeleted[$0.uuidString] == nil }) ?? true else { continue }
            if let index = local.items.firstIndex(where: { $0.id == item.id || (item.contentID != nil && $0.contentID == item.contentID) }) {
                let current = local.items[index]
                if (item.metadataChangedAt ?? item.modifiedAt ?? item.addedAt) > (current.metadataChangedAt ?? current.modifiedAt ?? current.addedAt) {
                    item.id = current.id; item.localFilename = current.localFilename; item.subtitleFilename = current.subtitleFilename; item.posterFilename = current.posterFilename
                } else { item = current }
                let remote = incoming.items.first { $0.id == item.id || ($0.contentID != nil && $0.contentID == item.contentID) }!
                if (remote.lastPlayedAt ?? .distantPast) > (current.lastPlayedAt ?? .distantPast) {
                    item.position = remote.position; item.duration = remote.duration; item.lastPlayedAt = remote.lastPlayedAt
                } else { item.position = current.position; item.duration = current.duration; item.lastPlayedAt = current.lastPlayedAt }
                if (remote.favoriteChangedAt ?? .distantPast) > (current.favoriteChangedAt ?? .distantPast) { item.favorite = remote.favorite; item.favoriteChangedAt = remote.favoriteChangedAt }
                else { item.favorite = current.favorite; item.favoriteChangedAt = current.favoriteChangedAt }
                if (remote.watchedChangedAt ?? .distantPast) > (current.watchedChangedAt ?? .distantPast) { item.watched = remote.watched; item.watchedChangedAt = remote.watchedChangedAt }
                else { item.watched = current.watched; item.watchedChangedAt = current.watchedChangedAt }
                item.modifiedAt = max(remote.modifiedAt ?? .distantPast, current.modifiedAt ?? .distantPast); local.items[index] = item
            } else {
                item.localFilename = nil; item.subtitleFilename = nil; item.posterFilename = nil; local.items.append(item)
            }
        }
        local.items.removeAll { deleted[$0.id.uuidString] != nil || $0.sourceID.map { sourcesDeleted[$0.uuidString] != nil } ?? false }
    }
}
