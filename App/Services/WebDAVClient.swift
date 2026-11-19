import Foundation

struct WebDAVClient {
    var source: MediaSource
    var secret: SourceSecret

    func authorized(_ url: URL) throws -> URLRequest {
        guard url.scheme == source.endpoint.scheme, url.host == source.endpoint.host, url.port == source.endpoint.port else {
            throw AppError.message("共享返回了其他服务器的地址，未发送凭证。")
        }
        var request = URLRequest(url: url)
        if !source.username.isEmpty {
            let basic = Data((source.username + ":" + secret.password).utf8).base64EncodedString()
            request.setValue("Basic " + basic, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    func list(path: String?) async throws -> [RemoteEntry] {
        guard var url = path.flatMap({ URL(string: $0) }) ?? Optional(source.endpoint) else { throw AppError.invalidURL }
        if !url.hasDirectoryPath { url.appendPathComponent("") }
        var request = try authorized(url)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("<?xml version=\"1.0\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:displayname/><d:resourcetype/><d:getcontentlength/></d:prop></d:propfind>".utf8)
        return try WebDAVParser.parse(await HTTPClient.send(request), relativeTo: url)
    }
}
