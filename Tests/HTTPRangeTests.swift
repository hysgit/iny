import XCTest
@testable import InyCore

final class HTTPRangeTests: XCTestCase {
    func testBoundedOpenAndSuffixRanges() throws {
        XCTAssertEqual(try HTTPByteRange.parse("bytes=2-5", size: 10), .init(start: 2, length: 4))
        XCTAssertEqual(try HTTPByteRange.parse("bytes=8-", size: 10), .init(start: 8, length: 2))
        XCTAssertEqual(try HTTPByteRange.parse("bytes=-3", size: 10), .init(start: 7, length: 3))
        XCTAssertThrowsError(try HTTPByteRange.parse("bytes=11-", size: 10))
        XCTAssertThrowsError(try HTTPByteRange.parse("bytes=2-1", size: 10))
        XCTAssertThrowsError(try HTTPByteRange.parse("bytes=1-2,3-4", size: 10))
    }
}
