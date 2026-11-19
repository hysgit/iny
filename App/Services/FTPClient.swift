import Foundation
import Network

private final class FTPSocket: @unchecked Sendable {
    let connection: NWConnection
    private var buffer = Data()
    init(host: String, port: UInt16) { connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp) }
    func open() async throws {
        try await withCheckedThrowingContinuation { (result: CheckedContinuation<Void, Error>) in
            var finished = false
            connection.stateUpdateHandler = { state in
                guard !finished else { return }
                switch state {
                case .ready: finished = true; result.resume()
                case .failed(let error): finished = true; result.resume(throwing: error)
                default: break
                }
            }
            connection.start(queue: DispatchQueue(label: "iny.ftp"))
        }
    }
    func send(_ text: String) async throws {
        guard !text.contains("\r"), !text.contains("\n") else { throw AppError.message("FTP 参数包含无效换行。") }
        try await withCheckedThrowingContinuation { (result: CheckedContinuation<Void, Error>) in
            connection.send(content: Data((text + "\r\n").utf8), completion: .contentProcessed { error in
                if let error { result.resume(throwing: error) } else { result.resume() }
            })
        }
    }
    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { result in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                if let error { result.resume(throwing: error) } else { result.resume(returning: data ?? Data()) }
            }
        }
    }
    func line() async throws -> String {
        while true {
            if let end = buffer.range(of: Data("\r\n".utf8)) {
                let text = String(decoding: buffer[..<end.lowerBound], as: UTF8.self); buffer.removeSubrange(..<end.upperBound); return text
            }
            let data = try await receive(); guard !data.isEmpty, buffer.count < 65536 else { throw AppError.invalidResponse }; buffer.append(data)
        }
    }
    func reply() async throws -> (Int, String) {
        let first = try await line(); guard let code = Int(first.prefix(3)) else { throw AppError.invalidResponse }
        var text = first
        if first.count > 3, first[first.index(first.startIndex, offsetBy: 3)] == "-" {
            while true { let next = try await line(); text += "\n" + next; if next.hasPrefix("\(code) ") { break } }
        }
        return (code, text)
    }
}

struct FTPClient {
    let source: MediaSource
    let secret: SourceSecret
    func list(path: String?) async throws -> [RemoteEntry] {
        guard let host = source.endpoint.host else { throw AppError.invalidURL }
        let control = FTPSocket(host: host, port: UInt16(source.endpoint.port ?? 21))
        try await control.open(); defer { control.connection.cancel() }
        guard try await control.reply().0 == 220 else { throw AppError.invalidResponse }
        try await control.send("USER " + (source.username.isEmpty ? "anonymous" : source.username))
        let login = try await control.reply().0
        if login == 331 { try await control.send("PASS " + secret.password); guard try await control.reply().0 == 230 else { throw AppError.message("FTP 登录失败。") } }
        else if login != 230 { throw AppError.message("FTP 登录失败。") }
        let directory = path ?? (source.endpoint.path.isEmpty ? "/" : source.endpoint.path)
        try await control.send("CWD " + directory); guard try await control.reply().0 == 250 else { throw AppError.message("无法打开 FTP 文件夹。") }
        for machine in [true, false] {
            try await control.send("EPSV"); var passive = try await control.reply()
            var port: UInt16?
            if passive.0 == 229, let open = passive.1.firstIndex(of: "("), let close = passive.1[open...].firstIndex(of: ")") {
                port = passive.1[passive.1.index(after: open)..<close].split(separator: "|").last.flatMap { UInt16($0) }
            } else {
                try await control.send("PASV"); passive = try await control.reply()
                if let open = passive.1.firstIndex(of: "("), let close = passive.1[open...].firstIndex(of: ")") {
                    let values = passive.1[passive.1.index(after: open)..<close].split(separator: ",").compactMap { UInt16($0.trimmingCharacters(in: .whitespaces)) }
                    if values.count == 6, values[4] < 256, values[5] < 256 { port = values[4] * 256 + values[5] }
                }
            }
            guard let port, port > 0 else { throw AppError.message("FTP 被动模式响应无效。") }
            let data = FTPSocket(host: host, port: port); try await data.open()
            try await control.send(machine ? "MLSD" : "LIST")
            let ready = try await control.reply().0
            if ready != 150 && ready != 125 { data.connection.cancel(); if machine { continue }; throw AppError.invalidResponse }
            var bytes = Data()
            while true { let part = try await data.receive(); if part.isEmpty { break }; bytes.append(part); guard bytes.count <= 16 * 1024 * 1024 else { throw AppError.message("FTP 目录过大。") } }
            data.connection.cancel(); guard try await control.reply().0 == 226 else { throw AppError.invalidResponse }
            return FTPDirectoryParser.parse(String(decoding: bytes, as: UTF8.self), parent: directory, machine: machine)
        }
        return []
    }
}
