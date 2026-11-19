import Foundation
#if canImport(Citadel)
import Citadel

actor SFTPClientAdapter {
    private let source: MediaSource
    private let secret: SourceSecret
    private var ssh: SSHClient?
    private var sftp: SFTPClient?
    init(source: MediaSource, secret: SourceSecret) { self.source = source; self.secret = secret }
    private func connect() async throws -> SFTPClient {
        if let sftp { return sftp }
        guard let host = source.endpoint.host, let key = source.hostKey, !key.isEmpty else { throw AppError.message("请填写服务器的 OpenSSH 主机公钥以验证 SFTP 身份。") }
        let username = source.username; let password = secret.password
        let settings = SSHClientSettings(host: host, port: source.endpoint.port ?? 22, authenticationMethod: { .passwordBased(username: username, password: password) }, hostKeyValidator: .trustedKeys([try .init(openSSHPublicKey: key)]))
        let client = try await SSHClient.connect(to: settings)
        let files = try await client.openSFTP(); ssh = client; sftp = files; return files
    }
    func list(path: String?) async throws -> [RemoteEntry] {
        let directory = path ?? (source.endpoint.path.isEmpty ? "/" : source.endpoint.path)
        let rows = try await connect().listDirectory(atPath: directory)
        return rows.flatMap(\.components).compactMap { component in
            let name = component.filename
            guard name != ".", name != "..", !name.contains("/") else { return nil }
            let folder = component.longname.hasPrefix("d")
            guard folder || MediaFormats.isVideo(name) else { return nil }
            let path = (directory as NSString).appendingPathComponent(name)
            return RemoteEntry(id: path, name: name, isDirectory: folder, path: path)
        }
    }
    func playback(path: String) async throws -> PlaybackResource {
        let files = try await connect(); let size = try await files.getAttributes(at: path).size ?? 0
        let file = try await files.openFile(filePath: path, flags: .read)
        let url = try await LocalMediaServer.shared.serve(length: Int64(size)) { offset, count in
            let bytes = try await file.read(from: UInt64(offset), length: UInt32(count))
            return Data(bytes.readableBytesView)
        }
        return PlaybackResource(url: url)
    }
}
#endif
