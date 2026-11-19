import Foundation

struct CloudDriveClient {
    let source: MediaSource
    let secret: SourceSecret
    static func endpoint(_ kind: SourceKind) -> URL {
        switch kind {
        case .googleDrive: return URL(string: "https://www.googleapis.com/drive/v3")!
        case .oneDrive: return URL(string: "https://graph.microsoft.com/v1.0")!
        case .aliyun: return URL(string: "https://openapi.alipan.com/adrive/v1.0")!
        default: return URL(string: "https://api.dropboxapi.com/2")!
        }
    }
    private func json(_ path: String, query: [String: String] = [:], body: [String: Any]? = nil, absolute: URL? = nil) async throws -> [String: Any] {
        let base = Self.endpoint(source.kind); let url = try absolute ?? URLTools.endpoint(base, path, query: query)
        guard url.host == base.host, url.scheme == "https" else { throw AppError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue("Bearer " + (try await CloudTokenBroker.shared.resolve(source, fallback: secret)).token, forHTTPHeaderField: "Authorization")
        if let body { request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        return try await HTTPClient.json(request)
    }
    func list(parent: String?) async throws -> [RemoteEntry] {
        switch source.kind {
        case .googleDrive:
            let parent = parent ?? (source.share.isEmpty ? "root" : source.share)
            guard !parent.contains("'") else { throw AppError.invalidURL }
            var result: [RemoteEntry] = []; var page = ""
            repeat {
                let value = try await json("files", query: ["q": "'\(parent)' in parents and trashed=false", "pageSize": "1000", "pageToken": page, "fields": "nextPageToken,files(id,name,mimeType)"])
                for row in value["files"] as? [[String: Any]] ?? [] {
                    if let id = row["id"] as? String, let name = row["name"] as? String {
                        let folder = row["mimeType"] as? String == "application/vnd.google-apps.folder"
                        if folder || MediaFormats.isVideo(name) { result.append(RemoteEntry(id: id, name: name, isDirectory: folder, path: id)) }
                    }
                }
                page = value["nextPageToken"] as? String ?? ""
            } while !page.isEmpty
            return result
        case .dropbox:
            var value = try await json("files/list_folder", body: ["path": parent ?? source.share, "recursive": false]); var result: [RemoteEntry] = []
            while true {
                for row in value["entries"] as? [[String: Any]] ?? [] {
                    if let id = row["id"] as? String, let name = row["name"] as? String {
                        let folder = row[".tag"] as? String == "folder"
                        if folder || MediaFormats.isVideo(name) { result.append(RemoteEntry(id: id, name: name, isDirectory: folder, path: row["path_display"] as? String ?? id)) }
                    }
                }
                guard value["has_more"] as? Bool == true, let cursor = value["cursor"] as? String else { return result }
                value = try await json("files/list_folder/continue", body: ["cursor": cursor])
            }
        case .oneDrive:
            var url = try URLTools.endpoint(Self.endpoint(.oneDrive), parent.map { "me/drive/items/\($0)/children" } ?? "me/drive/root/children")
            var result: [RemoteEntry] = []
            while true {
                let value = try await json("", absolute: url)
                for row in value["value"] as? [[String: Any]] ?? [] {
                    if let id = row["id"] as? String, let name = row["name"] as? String {
                        let folder = row["folder"] != nil
                        if folder || MediaFormats.isVideo(name) { result.append(RemoteEntry(id: id, name: name, isDirectory: folder, path: id)) }
                    }
                }
                guard let next = value["@odata.nextLink"] as? String, let nextURL = URL(string: next) else { return result }; url = nextURL
            }
        case .aliyun:
            let drive = try await driveID(); var marker = ""; var result: [RemoteEntry] = []
            repeat {
                let value = try await json("openFile/list", body: ["drive_id": drive, "parent_file_id": parent ?? "root", "limit": 100, "marker": marker])
                for row in value["items"] as? [[String: Any]] ?? [] {
                    if let id = row["file_id"] as? String, let name = row["name"] as? String {
                        let folder = row["type"] as? String == "folder"
                        if folder || MediaFormats.isVideo(name) { result.append(RemoteEntry(id: id, name: name, isDirectory: folder, path: id)) }
                    }
                }
                marker = value["next_marker"] as? String ?? ""
            } while !marker.isEmpty
            return result
        default: throw AppError.invalidResponse
        }
    }
    private func driveID() async throws -> String {
        if !source.share.isEmpty { return source.share }
        let value = try await json("user/getDriveInfo", body: [:])
        guard let id = (value["resource_drive_id"] ?? value["default_drive_id"]) as? String else { throw AppError.invalidResponse }; return id
    }
    func playback(id: String) async throws -> PlaybackResource {
        let link: String?
        switch source.kind {
        case .dropbox: link = try await json("files/get_temporary_link", body: ["path": id])["link"] as? String
        case .oneDrive: link = try await json("me/drive/items/\(id)", query: ["$select": "id,@microsoft.graph.downloadUrl"])["@microsoft.graph.downloadUrl"] as? String
        case .aliyun:
            let drive = try await driveID(); link = try await json("openFile/getDownloadUrl", body: ["drive_id": drive, "file_id": id])["url"] as? String
        case .googleDrive:
            let credential = try await CloudTokenBroker.shared.resolve(source, fallback: secret)
            let info = try await json("files/\(id)", query: ["fields": "size"])
            guard let count = info["size"] as? String, let size = Int64(count) else { throw AppError.invalidResponse }
            let remote = try URLTools.endpoint(Self.endpoint(.googleDrive), "files/\(id)", query: ["alt": "media"])
            let local = try await LocalMediaServer.shared.remote(remote, length: size, bearer: credential.token)
            return PlaybackResource(url: local)
        default: throw AppError.invalidResponse
        }
        guard let link, let url = URL(string: link), url.scheme == "https" else { throw AppError.invalidResponse }
        return PlaybackResource(url: url)
    }
}
