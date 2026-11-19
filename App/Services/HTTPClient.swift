import Foundation

final class HTTPRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let original = task.originalRequest?.url, let target = request.url,
              original.scheme == target.scheme, original.host == target.host, original.port == target.port else {
            completionHandler(nil); return
        }
        completionHandler(request)
    }
}

enum HTTPClient {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.urlCredentialStorage = nil
        config.httpCookieStorage = nil
        return URLSession(configuration: config, delegate: HTTPRedirectPolicy(), delegateQueue: nil)
    }()

    static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw AppError.http(http.statusCode) }
        return data
    }

    static func json(_ request: URLRequest) async throws -> [String: Any] {
        let data = try await send(request)
        if data.isEmpty { return [:] }
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AppError.invalidResponse }
        return result
    }
}
