import Foundation
#if canImport(AMSMB2)
import AMSMB2
#endif

struct SMBClient {
    var source: MediaSource
    var secret: SourceSecret

    func list(path: String?) async throws -> [RemoteEntry] {
        #if canImport(AMSMB2)
        guard let manager = SMB2Manager(url: source.endpoint, credential: URLCredential(user: source.username, password: secret.password, persistence: .none)) else {
            throw AppError.invalidURL
        }
        guard !source.share.isEmpty else { throw AppError.message("请填写 SMB 共享名称，例如 Movies。") }
        try await manager.connectShare(name: source.share)
        let rows = try await manager.contentsOfDirectory(atPath: path ?? "/")
        return rows.compactMap { value in
            guard let name = value[.nameKey] as? String, let filePath = value[.pathKey] as? String else { return nil }
            let folder = value[.isDirectoryKey] as? Bool ?? false
            guard folder || MediaFormats.isVideo(name) else { return nil }
            return RemoteEntry(id: filePath, name: name, isDirectory: folder, path: filePath)
        }.sorted { a, b in a.isDirectory != b.isDirectory ? a.isDirectory : a.name.localizedStandardCompare(b.name) == .orderedAscending }
        #else
        throw AppError.message("此构建未链接 AMSMB2。请使用完整 Xcode 工程解析 Swift Package 依赖。")
        #endif
    }

    func playback(path: String) throws -> PlaybackResource {
        var url = source.endpoint.appendingPathComponent(source.share)
        for segment in path.split(separator: "/") { url.appendPathComponent(String(segment)) }
        return PlaybackResource(url: url, username: source.username, password: secret.password)
    }
}
