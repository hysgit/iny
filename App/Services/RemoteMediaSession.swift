import Foundation

final class RemoteMediaRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme == "https" else { completionHandler(nil); return }
        var next = request
        if task.originalRequest?.url?.host != next.url?.host { next.setValue(nil, forHTTPHeaderField: "Authorization") }
        completionHandler(next)
    }
}

enum RemoteMediaSession {
    static let session = URLSession(configuration: .ephemeral, delegate: RemoteMediaRedirect(), delegateQueue: nil)
    static func read(_ url: URL, bearer: String, offset: Int64, count: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        request.setValue("bytes=\(offset)-\(offset + Int64(count) - 1)", forHTTPHeaderField: "Range")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 206 || (response.statusCode == 200 && offset == 0) else { throw AppError.invalidResponse }
        var result = Data(); result.reserveCapacity(count)
        for try await byte in bytes { result.append(byte); if result.count >= count { break } }
        return result
    }
}

extension LocalMediaServer {
    func remote(_ url: URL, length: Int64, bearer: String) async throws -> URL {
        try await serve(length: length) { offset, count in try await RemoteMediaSession.read(url, bearer: bearer, offset: offset, count: count) }
    }
}
