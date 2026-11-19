import Foundation
import Combine

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var library = LibrarySnapshot()
    @Published private(set) var loaded = false
    @Published var error: String?
    @Published var activity: String?
    @Published var downloadProgress: [UUID: Double] = [:]
    private var downloads: [UUID: Task<Void, Never>] = [:]
    let repository: LibraryRepository

    init() {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Library", isDirectory: true)
        repository = LibraryRepository(directory: directory)
    }

    func load() async {
        do { try await refresh(); loaded = true }
        catch { self.error = "媒体库读取失败，原文件已保留。\n" + error.localizedDescription }
    }

    func perform(_ operation: () async throws -> Void) async {
        do { try await operation() }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }

    // actor 返回顺序与主线程恢复顺序可能不同，只接受不早于当前版本的快照。
    func refresh() async throws {
        let next = try await repository.load()
        if (next.revision ?? 0) >= (library.revision ?? 0) { library = next }
    }

    func importFiles(_ urls: [URL]) async {
        activity = "正在导入视频…"
        defer { activity = nil }
        for url in urls {
            await perform {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                _ = try await repository.importFile(url)
                try await refresh()
            }
        }
    }

    func addStream(_ text: String, title: String) async throws {
        let url = try URLTools.cleanStream(text)
        _ = try await repository.add(MediaItem(title: title.isEmpty ? MediaFormats.title(url.lastPathComponent) : title, directURL: url))
        try await refresh()
    }

    func secret(for source: MediaSource) throws -> SourceSecret {
        try KeychainVault.read(SourceSecret.self, account: source.id.uuidString) ?? SourceSecret()
    }

    func addSource(_ source: MediaSource, secret: SourceSecret) async throws {
        var source = source; var secret = secret
        if [.jellyfin, .emby, .plex].contains(source.kind) {
            (source, secret) = try await MediaServerClient(source: source, secret: secret).authenticate()
        } else if source.kind == .webdav { _ = try await WebDAVClient(source: source, secret: secret).list(path: nil) }
        else if source.kind == .smb { _ = try await SMBClient(source: source, secret: secret).list(path: nil) }
        else { _ = try await entriesFor(source, secret: secret, parent: nil) }
        try KeychainVault.save(secret, account: source.id.uuidString)
        do { _ = try await repository.addSource(source) }
        catch { try? KeychainVault.delete(account: source.id.uuidString); throw error }
        try await refresh()
    }

    func removeSource(_ source: MediaSource) async throws {
        for item in library.items where item.sourceID == source.id { downloads[item.id]?.cancel() }
        _ = try await repository.removeSource(source.id)
        try await refresh()
        try KeychainVault.delete(account: source.id.uuidString)
    }

    func entries(_ source: MediaSource, parent: String?) async throws -> [RemoteEntry] {
        let secret = try secret(for: source)
        return try await entriesFor(source, secret: secret, parent: parent)
    }
    private func entriesFor(_ source: MediaSource, secret: SourceSecret, parent: String?) async throws -> [RemoteEntry] {
        switch source.kind {
        case .webdav: return try await WebDAVClient(source: source, secret: secret).list(path: parent)
        case .smb: return try await SMBClient(source: source, secret: secret).list(path: parent)
        case .jellyfin, .emby, .plex: return try await MediaServerClient(source: source, secret: secret).list(parent: parent)
        case .ftp: return try await FTPClient(source: source, secret: secret).list(path: parent)
        case .nfs: return try await NFSClientAdapter(source: source).list(path: parent)
        case .sftp:
            #if canImport(Citadel)
            return try await SFTPClientAdapter(source: source, secret: secret).list(path: parent)
            #else
            throw AppError.message("此版本没有 SFTP 客户端。")
            #endif
        case .dropbox, .googleDrive, .oneDrive, .aliyun: return try await CloudDriveClient(source: source, secret: secret).list(parent: parent)
        }
    }

    func addEntry(_ entry: RemoteEntry, source: MediaSource) async throws -> MediaItem {
        let item = MediaItem(title: entry.name, sourceID: source.id, remoteID: entry.id, remotePath: entry.path,
                             posterURL: entry.posterURL, overview: entry.overview, year: entry.year,
                             duration: entry.duration, position: entry.position, watched: entry.watched, mediaType: entry.mediaType)
        _ = try await repository.add(item)
        try await refresh()
        return library.items.first { $0.sourceID == source.id && $0.remoteID == entry.id } ?? item
    }

    func resource(_ item: MediaItem) async throws -> PlaybackResource {
        if let filename = item.localFilename { return PlaybackResource(url: try await repository.localURL(filename)) }
        if let url = item.directURL { return PlaybackResource(url: url) }
        guard let source = library.sources.first(where: { $0.id == item.sourceID }), let id = item.remoteID else { throw AppError.message("影片来源不存在，请重新添加。") }
        let secret = try secret(for: source)
        switch source.kind {
        case .webdav:
            guard let path = item.remotePath, let url = URL(string: path) else { throw AppError.invalidURL }
            _ = try WebDAVClient(source: source, secret: secret).authorized(url)
            return PlaybackResource(url: url, username: source.username, password: secret.password)
        case .smb: return try SMBClient(source: source, secret: secret).playback(path: item.remotePath ?? id)
        case .ftp:
            guard var parts = URLComponents(url: source.endpoint, resolvingAgainstBaseURL: false) else { throw AppError.invalidURL }
            parts.path = item.remotePath ?? id; parts.user = source.username; parts.password = secret.password
            return PlaybackResource(url: parts.url!)
        case .nfs:
            var url = source.endpoint.appendingPathComponent(source.share)
            for part in (item.remotePath ?? id).split(separator: "/") { url.appendPathComponent(String(part)) }
            return PlaybackResource(url: url)
        case .sftp:
            #if canImport(Citadel)
            return try await SFTPClientAdapter(source: source, secret: secret).playback(path: item.remotePath ?? id)
            #else
            throw AppError.message("此版本没有 SFTP 客户端。")
            #endif
        case .dropbox, .googleDrive, .oneDrive, .aliyun: return try await CloudDriveClient(source: source, secret: secret).playback(id: id)
        default: return try await MediaServerClient(source: source, secret: secret).playback(id: id)
        }
    }

    func artwork(_ item: MediaItem) async -> Data? {
        do {
            if let file = item.posterFilename { return try Data(contentsOf: await repository.localURL(file)) }
            if let url = item.posterURL { return try await HTTPClient.send(URLRequest(url: url)) }
            guard let source = library.sources.first(where: { $0.id == item.sourceID }), let id = item.remoteID,
                  [.jellyfin, .emby, .plex].contains(source.kind) else { return nil }
            return try await MediaServerClient(source: source, secret: secret(for: source)).artwork(id: id)
        } catch { return nil }
    }

    func update(_ id: UUID, _ body: (inout MediaItem) -> Void) async throws {
        _ = try await repository.update(id, body)
        try await refresh()
    }

    func progress(_ item: MediaItem, position: Double, duration: Double) async throws {
        guard position.isFinite, duration.isFinite, position >= 0 else { return }
        let capturedAt = Date()
        _ = try await repository.saveProgress(item.id, position: position, duration: duration, capturedAt: capturedAt)
        try await refresh()
    }

    func report(_ item: MediaItem, position: Double, stopped: Bool, paused: Bool = false, started: Bool = false) async {
        if UserDefaults.standard.bool(forKey: "traktScrobbling") {
            do { try await TraktClient.shared.scrobble(item, position: position, duration: item.duration, action: stopped ? "stop" : (paused ? "pause" : "start")) }
            catch { self.error = "Trakt 同步未完成：" + error.localizedDescription }
        }
        guard let source = library.sources.first(where: { $0.id == item.sourceID }), let id = item.remoteID,
              [.jellyfin, .emby, .plex].contains(source.kind) else { return }
        do {
            let client = try MediaServerClient(source: source, secret: secret(for: source))
            if started { try await client.start(id: id, position: position) }
            else { try await client.report(id: id, position: position, stopped: stopped, paused: paused) }
        } catch { self.error = "本地进度已保存，但服务器进度同步失败：" + error.localizedDescription }
    }

    func attachSubtitle(_ url: URL, item: MediaItem) async throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        _ = try await repository.importSubtitle(url, for: item.id)
        try await refresh()
    }

    func remove(_ item: MediaItem) async throws {
        downloads[item.id]?.cancel()
        _ = try await repository.remove(item.id)
        try await refresh()
    }

    func download(_ item: MediaItem) {
        guard downloads[item.id] == nil else { return }
        downloads[item.id] = Task {
            downloadProgress[item.id] = 0
            defer { downloads[item.id] = nil; downloadProgress[item.id] = nil }
            await perform {
                let resource = try await resource(item)
                guard ["http", "https"].contains(resource.url.scheme ?? ""), resource.url.pathExtension.lowercased() != "m3u8" else {
                    throw AppError.message("离线下载支持 HTTP 视频文件；SMB 和 HLS 请先通过“文件”导入。")
                }
                var request = URLRequest(url: resource.url)
                if let user = resource.username, !user.isEmpty {
                    request.setValue("Basic " + Data((user + ":" + (resource.password ?? "")).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
                }
                let id = item.id
                let temporary = try await DownloadService().download(request) { [weak self] value in
                    Task { @MainActor in self?.downloadProgress[id] = value }
                }
                defer { try? FileManager.default.removeItem(at: temporary) }
                try Task.checkCancellation()
                _ = try await repository.importFile(temporary, title: item.title)
                try await refresh()
            }
        }
    }

    func cancelDownload(_ id: UUID) { downloads[id]?.cancel() }
}
