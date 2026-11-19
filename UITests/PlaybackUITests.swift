import XCTest

final class PlaybackUITests: XCTestCase {
    @MainActor
    func testLocalVideoPlaybackPauseAndClose() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let sample = app.staticTexts["Iny 播放验收样片"].firstMatch
        XCTAssertTrue(sample.waitForExistence(timeout: 15))
        sample.tap()
        let play = app.buttons["media-play"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()
        let toggle = app.buttons["playback-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 15))
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "播放中"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 15), .completed)
        Thread.sleep(forTimeInterval: 2)
        toggle.tap()
        let paused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "已暂停"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: 10), .completed)
        try app.screenshot().pngRepresentation.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("Iny-playback.png"))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["player-close"].tap()
        XCTAssertTrue(app.buttons["media-play"].waitForExistence(timeout: 10))
    }
}
