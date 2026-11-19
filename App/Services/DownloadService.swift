import Foundation

// 前台任务由 URLSession 写临时文件，不把整部影片读入内存。
final class DownloadService: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var destination: URL?
    private var progress: (@Sendable (Double) -> Void)?

    func download(_ request: URLRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 86400
        config.urlCredentialStorage = nil
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation; self.progress = progress
                let task = session.downloadTask(with: request); self.task = task
                let shouldCancel = cancelled
                lock.unlock()
                task.resume()
                if shouldCancel { task.cancel() }
            }
        } onCancel: { self.cancel() }
    }

    private func cancel() {
        lock.lock(); cancelled = true; let current = task; lock.unlock()
        current?.cancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { progress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let old = task.originalRequest?.url, let new = request.url,
              old.host == new.host, old.scheme == new.scheme, old.port == new.port else { completionHandler(nil); return }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                throw AppError.http((downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            let ext = downloadTask.originalRequest?.url?.pathExtension.lowercased() ?? "mp4"
            let suffix = MediaFormats.video.contains(ext) ? ext : "mp4"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + suffix)
            try FileManager.default.moveItem(at: location, to: url)
            destination = url
        } catch { complete(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { complete(.failure(error)) }
        else if let destination { complete(.success(destination)) }
        else { complete(.failure(AppError.invalidResponse)) }
    }

    private func complete(_ result: Result<URL, Error>) {
        lock.lock(); let handler = continuation; continuation = nil; lock.unlock()
        handler?.resume(with: result)
    }
}
