import XCTest
@testable import InyCore

final class LibraryRepositoryTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testConcurrentAddsKeepEveryItem() async throws {
        let repository = try LibraryRepository(directory: directory())
        try await withThrowingTaskGroup(of: Void.self) { group in
            for number in 0..<100 {
                group.addTask { _ = try await repository.add(MediaItem(title: "影片 \(number)")) }
            }
            try await group.waitForAll()
        }
        let result = try await repository.load()
        XCTAssertEqual(result.items.count, 100)
        XCTAssertEqual(result.revision, 100)
        let reopened = LibraryRepository(directory: await repository.directory)
        let reloaded = try await reopened.load()
        XCTAssertEqual(Set(reloaded.items.map(\.id)), Set(result.items.map(\.id)))
    }

    func testRemoteIdentityIsDeduplicatedPerSource() async throws {
        let repository = try LibraryRepository(directory: directory())
        let first = MediaSource(name: "one", kind: .webdav, endpoint: URL(string: "https://one.example")!)
        let second = MediaSource(name: "two", kind: .webdav, endpoint: URL(string: "https://two.example")!)
        _ = try await repository.addSource(first)
        _ = try await repository.addSource(second)
        _ = try await repository.add(MediaItem(title: "one", sourceID: first.id, remoteID: "same"))
        _ = try await repository.add(MediaItem(title: "two", sourceID: first.id, remoteID: "same"))
        _ = try await repository.add(MediaItem(title: "three", sourceID: second.id, remoteID: "same"))
        let result = try await repository.load()
        XCTAssertEqual(result.items.count, 2)
    }

    func testCorruptLibraryIsNotOverwritten() async throws {
        let dir = try directory()
        let index = dir.appendingPathComponent("library.json")
        let bytes = Data("broken original index".utf8)
        try bytes.write(to: index)
        let repository = LibraryRepository(directory: dir)
        do { _ = try await repository.add(MediaItem(title: "new")); XCTFail("Expected corruption error") } catch { }
        XCTAssertEqual(try Data(contentsOf: index), bytes)
    }

    func testFailedWriteDoesNotPublishMutation() async throws {
        let dir = try directory()
        let repository = LibraryRepository(directory: dir)
        _ = try await repository.load()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("library.json"), withIntermediateDirectories: false)
        do { _ = try await repository.add(MediaItem(title: "not saved")); XCTFail("Expected write failure") } catch { }
        let result = try await repository.load()
        XCTAssertTrue(result.items.isEmpty)
    }

    func testImportCopiesMediaAndDeletionPreservesOriginal() async throws {
        let dir = try directory()
        let original = dir.appendingPathComponent("original.MP4")
        let bytes = Data([0, 1, 2, 3, 4])
        try bytes.write(to: original)
        let repository = LibraryRepository(directory: dir.appendingPathComponent("library"))
        let imported = try await repository.importFile(original)
        let item = try XCTUnwrap(imported.items.first)
        let stored = try await repository.localURL(XCTUnwrap(item.localFilename))
        XCTAssertEqual(try Data(contentsOf: stored), bytes)
        _ = try await repository.remove(item.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stored.path))
        XCTAssertEqual(try Data(contentsOf: original), bytes)
    }

    func testPathTraversalIsRejected() async throws {
        let repository = try LibraryRepository(directory: directory())
        for path in ["../outside.mp4", "/outside.mp4", "..", "", "folder/file.mp4"] {
            do { _ = try await repository.localURL(path); XCTFail("Accepted invalid path: \(path)") } catch { }
        }
    }

    func testProgressAndFavoriteChangesAreBothRetained() async throws {
        let repository = try LibraryRepository(directory: directory())
        let item = MediaItem(title: "video")
        _ = try await repository.add(item)
        async let first = repository.update(item.id) { $0.position = 125; $0.duration = 400 }
        async let second = repository.update(item.id) { $0.favorite = true }
        _ = try await (first, second)
        let result = try await repository.load()
        XCTAssertEqual(result.items.first?.position, 125)
        XCTAssertEqual(result.items.first?.favorite, true)
    }

    func testRemovingSourceKeepsLocalVideos() async throws {
        let repository = try LibraryRepository(directory: directory())
        let source = MediaSource(name: "NAS", kind: .webdav, endpoint: URL(string: "https://nas.example")!)
        _ = try await repository.addSource(source)
        _ = try await repository.add(MediaItem(title: "remote", sourceID: source.id, remoteID: "1"))
        _ = try await repository.add(MediaItem(title: "local", localFilename: "safe.mp4"))
        let result = try await repository.removeSource(source.id)
        XCTAssertTrue(result.sources.isEmpty)
        XCTAssertEqual(result.items.map(\.title), ["local"])
        do { _ = try await repository.add(MediaItem(title: "late network result", sourceID: source.id, remoteID: "2")); XCTFail("Removed source was resurrected") } catch { }
    }
}
