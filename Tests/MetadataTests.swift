import XCTest
@testable import InyCore

final class MetadataTests: XCTestCase {
    func testEpisodeNamesAndYear() {
        let episode = FilenameMetadata.parse("Planet.Earth.S02E03.2160p.mkv")
        XCTAssertEqual(episode.title, "Planet Earth"); XCTAssertEqual(episode.season, 2); XCTAssertEqual(episode.episode, 3)
        let movie = FilenameMetadata.parse("电影 (2024) 1080p.mp4")
        XCTAssertEqual(movie.title, "电影"); XCTAssertEqual(movie.year, 2024)
        XCTAssertEqual(FilenameMetadata.parse("Series 1x12.avi").episode, 12)
    }

    func testNFODoesNotMixActorAndCollectionNames() throws {
        let xml = "<movie><title>影片</title><plot><![CDATA[简介 & 其他]]></plot><year>2024</year><set><name>系列</name></set><uniqueid type=\"tmdb\">123</uniqueid><actor><name>演员</name><role>角色</role></actor><mpaa>PG-13</mpaa></movie>"
        let metadata = try NFOMetadata.parse(Data(xml.utf8))
        XCTAssertEqual(metadata.title, "影片"); XCTAssertEqual(metadata.plot, "简介 & 其他")
        XCTAssertEqual(metadata.collection, "系列"); XCTAssertEqual(metadata.cast.first?.name, "演员")
        XCTAssertEqual(metadata.tmdbID, 123); XCTAssertEqual(metadata.certification, "PG-13")
        XCTAssertThrowsError(try NFOMetadata.parse(Data("<movie><title>broken".utf8)))
    }

    func testOlderCheckpointCannotRewindNewerProgress() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = LibraryRepository(directory: folder); let item = MediaItem(title: "test")
        _ = try await repository.add(item)
        _ = try await repository.saveProgress(item.id, position: 30, duration: 100, capturedAt: Date(timeIntervalSince1970: 200))
        let result = try await repository.saveProgress(item.id, position: 10, duration: 100, capturedAt: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(result.items.first?.position, 30)
    }
}
