import XCTest
@testable import InyCore

final class ProtocolTests: XCTestCase {
    func testEndpointPreservesReverseProxyPrefixAndEncodesValues() throws {
        let url = try URLTools.endpoint(URL(string: "https://nas.example/jellyfin")!, "Users/a/Items", query: ["query": "中文 & #/+", "api_key": "a&b"])
        XCTAssertEqual(url.path, "/jellyfin/Users/a/Items")
        let values = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(values?.first { $0.name == "query" }?.value, "中文 & #/+")
        XCTAssertEqual(values?.first { $0.name == "api_key" }?.value, "a&b")
    }

    func testServersRejectCredentialsAndUnexpectedSchemes() throws {
        for input in ["file:///tmp/movie", "https://user:password@nas.example", "javascript:alert(1)", "https://nas.example?api_key=secret", "https://"] {
            XCTAssertThrowsError(try URLTools.server(input))
        }
        XCTAssertEqual(try URLTools.server("https://nas.example:8096/base").port, 8096)
    }

    func testStreamsDoNotPersistKnownAuthenticationParameters() throws {
        for name in ["api_key", "token", "X-Plex-Token", "access_token", "password"] {
            XCTAssertThrowsError(try URLTools.cleanStream("https://nas.example/movie.mp4?\(name)=secret"))
        }
        XCTAssertEqual(try URLTools.cleanStream("https://nas.example/movie.mp4?quality=original").query, "quality=original")
    }

    func testWebDAVNamespacesRelativeHrefsAndXMLSpecialCharacters() throws {
        let xml = """
        <d:multistatus xmlns:d="DAV:">
          <d:response><d:href>/dav/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
          <d:response><d:href>/dav/%E4%B8%AD%E6%96%87%20%26%20film.mkv</d:href><d:propstat><d:prop><d:displayname>中文 &amp; film.mkv</d:displayname><d:resourcetype/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
          <d:response><d:href>folder/</d:href><d:propstat><d:prop><d:displayname>目录</d:displayname><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
          <d:response><d:href>/dav/readme.txt</d:href><d:propstat><d:prop/><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        </d:multistatus>
        """
        let entries = try WebDAVParser.parse(Data(xml.utf8), relativeTo: URL(string: "https://nas.example/dav/")!)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first?.name, "目录")
        XCTAssertEqual(entries.last?.name, "中文 & film.mkv")
        XCTAssertEqual(URL(string: entries.last!.path)?.path, "/dav/中文 & film.mkv")
    }

    func testWebDAVDoesNotForwardEntriesToOtherOrigins() throws {
        let xml = """
        <multistatus xmlns="DAV:"><response><href>https://other.example/video.mp4</href><propstat><prop/><status>HTTP/1.1 200 OK</status></propstat></response></multistatus>
        """
        XCTAssertTrue(try WebDAVParser.parse(Data(xml.utf8), relativeTo: URL(string: "https://nas.example/dav/")!).isEmpty)
    }

    func testInvalidXMLFailsRatherThanReturningPartialDirectory() {
        XCTAssertThrowsError(try WebDAVParser.parse(Data("<multistatus><response>".utf8), relativeTo: URL(string: "https://nas.example")!))
    }

    func testWebDAVRejectsFailedPropertyStatus() throws {
        let xml = "<multistatus xmlns=\"DAV:\"><response><href>/missing.mkv</href><propstat><prop/><status>HTTP/1.1 404 Not Found</status></propstat></response></multistatus>"
        XCTAssertTrue(try WebDAVParser.parse(Data(xml.utf8), relativeTo: URL(string: "https://nas.example/")!).isEmpty)
    }

    func testProgressIsClamped() {
        var item = MediaItem(title: "video", duration: 100, position: 120)
        XCTAssertEqual(item.progress, 1)
        item.position = -5
        XCTAssertEqual(item.progress, 0)
    }
}
