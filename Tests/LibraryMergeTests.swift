import XCTest
@testable import InyCore

final class LibraryMergeTests: XCTestCase {
    func testIndependentFavoriteAndProgressChangesAreBothRetained() {
        let base = MediaItem(title: "movie", localFilename: "own.mp4")
        var local = LibrarySnapshot(); var own = base; own.position = 30; own.lastPlayedAt = Date(timeIntervalSince1970: 200)
        local.items = [own]
        var remote = base; remote.favorite = true; remote.favoriteChangedAt = Date(timeIntervalSince1970: 300); remote.modifiedAt = Date(timeIntervalSince1970: 300); remote.localFilename = "other-device.mp4"
        var incoming = LibrarySnapshot(); incoming.items = [remote]
        LibraryMerge.apply(incoming, to: &local)
        XCTAssertEqual(local.items[0].position, 30); XCTAssertTrue(local.items[0].favorite); XCTAssertEqual(local.items[0].localFilename, "own.mp4")
    }
    func testDeletionWinsAgainstStaleDeviceAndDoesNotResurrect() {
        let item = MediaItem(title: "deleted")
        var local = LibrarySnapshot(); local.deletedItems = [item.id.uuidString: Date()]
        var oldDevice = LibrarySnapshot(); oldDevice.items = [item]
        LibraryMerge.apply(oldDevice, to: &local); XCTAssertTrue(local.items.isEmpty)
    }
}
