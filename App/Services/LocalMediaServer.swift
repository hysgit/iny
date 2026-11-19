import Foundation
import Network
import Darwin

@MainActor
final class LocalMediaServer {
    static let shared = LocalMediaServer()
    typealias Reader = @Sendable (Int64, Int) async throws -> Data
    private struct Entry { var length: Int64; var read: Reader }
    private var entries: [String: Entry] = [:]
    private var listener: NWListener?
    private var port: UInt16 = 0
    private let queue = DispatchQueue(label: "iny.media.http")

    func serve(length: Int64, reader: @escaping Reader) async throws -> URL {
        try await start()
        let id = UUID().uuidString; entries[id] = Entry(length: length, read: reader)
        return URL(string: "http://127.0.0.1:\(port)/\(id)/video")!
    }

    func file(_ url: URL, onLAN: Bool = false) async throws -> URL {
        let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        let local = try await serve(length: Int64(size)) { offset, count in
            try await Task.detached(priority: .utility) {
                let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
                try file.seek(toOffset: UInt64(offset)); return try file.read(upToCount: count) ?? Data()
            }.value
        }
        guard onLAN else { return local }
        var parts = URLComponents(url: local, resolvingAgainstBaseURL: false)!
        guard let ip = Self.wifiAddress() else { throw AppError.message("请连接 Wi-Fi 后重试。") }
        parts.host = ip; return parts.url!
    }

    private func start() async throws {
        if listener != nil { return }
        let server = try NWListener(using: .tcp, on: .any)
        server.newConnectionHandler = { [weak self] connection in
            connection.start(queue: DispatchQueue.global(qos: .userInitiated))
            Task { @MainActor in await self?.handle(connection) }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var completed = false
            server.stateUpdateHandler = { state in
                switch state {
                case .ready: if !completed { completed = true; continuation.resume() }
                case .failed(let error): if !completed { completed = true; continuation.resume(throwing: error) }
                default: break
                }
            }
            server.start(queue: queue)
        }
        port = server.port!.rawValue; listener = server
    }

    private func handle(_ connection: NWConnection) async {
        defer { connection.cancel() }
        do {
            var input = Data()
            while input.range(of: Data("\r\n\r\n".utf8)) == nil {
                let part = try await receive(connection)
                guard !part.isEmpty, input.count < 32768 else { return }; input.append(part)
            }
            let text = String(decoding: input, as: UTF8.self); let lines = text.components(separatedBy: "\r\n")
            let first = lines[0].split(separator: " ")
            guard first.count >= 2, ["GET", "HEAD"].contains(String(first[0])),
                  let id = first[1].split(separator: "/").first, let entry = entries[String(id)] else {
                try await send(connection, Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)); return
            }
            let rangeHeader = lines.first { $0.lowercased().hasPrefix("range:") }.map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
            let range: HTTPByteRange
            do { range = try HTTPByteRange.parse(rangeHeader, size: entry.length) }
            catch { try await send(connection, Data("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(entry.length)\r\nContent-Length: 0\r\n\r\n".utf8)); return }
            var header = "HTTP/1.1 \(rangeHeader == nil ? "200 OK" : "206 Partial Content")\r\nContent-Type: application/octet-stream\r\nAccept-Ranges: bytes\r\nContent-Length: \(range.length)\r\nConnection: close\r\n"
            if rangeHeader != nil { header += "Content-Range: bytes \(range.start)-\(range.start + range.length - 1)/\(entry.length)\r\n" }
            try await send(connection, Data((header + "\r\n").utf8))
            guard first[0] != "HEAD" else { return }
            var offset = range.start; let end = range.start + range.length
            while offset < end {
                let data = try await entry.read(offset, Int(min(262144, end - offset)))
                guard !data.isEmpty else { throw AppError.message("文件提前结束。") }
                try await send(connection, data); offset += Int64(data.count)
            }
        } catch { }
    }

    private func receive(_ connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) { data, _, _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: data ?? Data()) }
            }
        }
    }
    private func send(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    static func wifiAddress() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0 else { return nil }; defer { freeifaddrs(pointer) }
        var current = pointer
        while let item = current {
            defer { current = item.pointee.ifa_next }
            guard String(cString: item.pointee.ifa_name) == "en0", let address = item.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 { return String(cString: host) }
        }
        return nil
    }
}
