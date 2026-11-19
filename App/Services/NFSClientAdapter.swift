import Foundation
#if canImport(NFSKit)
import NFSKit
#endif

struct NFSClientAdapter {
    let source: MediaSource
    func list(path: String?) async throws -> [RemoteEntry] {
        #if canImport(NFSKit)
        guard let client = try NFSClient(url: source.endpoint) else { throw AppError.invalidURL }
        if let error = await client.connect(export: source.share) { throw error }
        let values = try await client.contentsOfDirectory(atPath: path ?? "/").get()
        try await client.disconnect(export: source.share)
        return values.compactMap { row in
            guard let name = row[.nameKey] as? String, let path = row[.pathKey] as? String, name != ".", name != ".." else { return nil }
            let folder = row[.isDirectoryKey] as? Bool ?? false
            guard folder || MediaFormats.isVideo(name) else { return nil }
            return RemoteEntry(id: path, name: name, isDirectory: folder, path: path)
        }
        #else
        throw AppError.message("此版本没有 NFS 客户端。")
        #endif
    }
}
