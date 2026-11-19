import Foundation

enum SourceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case webdav, jellyfin, emby, plex, smb
    var id: String { rawValue }
    var title: String {
        switch self {
        case .webdav: return "WebDAV"
        case .jellyfin: return "Jellyfin"
        case .emby: return "Emby"
        case .plex: return "Plex"
        case .smb: return "SMB"
        }
    }
}

struct MediaSource: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var kind: SourceKind
    var endpoint: URL
    var username = ""
    var userID: String?
    var share = ""
}

struct MediaItem: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var title: String
    // 本地只存 Documents 下的相对文件名；远程只存资源标识，不存带令牌的播放 URL。
    var localFilename: String?
    var sourceID: UUID?
    var remoteID: String?
    var remotePath: String?
    var directURL: URL?
    var posterURL: URL?
    var overview = ""
    var year: Int?
    var duration: Double = 0
    var position: Double = 0
    var watched = false
    var favorite = false
    var addedAt = Date()
    var lastPlayedAt: Date?
    var subtitleFilename: String?
    var tmdbID: Int?
    var mediaType = "movie"
    var seriesTitle: String?
    var season: Int?
    var episode: Int?
    var collection: String?
    var rating: Double?
    var certification: String?
    var cast: [MediaPerson]?
    var posterFilename: String?
    var modifiedAt: Date?
    var progress: Double { duration > 0 ? min(max(position / duration, 0), 1) : 0 }
    var isLocal: Bool { localFilename != nil }
}

struct MediaPerson: Codable, Hashable, Identifiable, Sendable {
    var id: String { name + (role ?? "") }
    var name: String
    var role: String?
    var portrait: URL?
}

struct LibrarySnapshot: Codable, Sendable {
    var version = 1
    var revision: Int?
    var items: [MediaItem] = []
    var sources: [MediaSource] = []
}

struct RemoteEntry: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var isDirectory: Bool
    var path: String
    var posterURL: URL?
    var overview = ""
    var year: Int?
    var duration: Double = 0
    var mediaType = "movie"
    var position: Double = 0
    var watched = false
}

struct PlaybackResource: Sendable {
    var url: URL
    var username: String?
    var password: String?
}

enum AppError: LocalizedError {
    case message(String)
    case http(Int)
    case invalidURL
    case invalidResponse
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .http(let code): return "服务器返回 HTTP \(code)。请检查地址、权限和登录信息。"
        case .invalidURL: return "地址无效，请输入与所选来源类型一致的完整服务器地址。"
        case .invalidResponse: return "服务器响应格式不正确。"
        }
    }
}

enum MediaFormats {
    static let video: Set<String> = ["mp4", "m4v", "mov", "mkv", "avi", "webm", "ts", "m2ts", "mts", "wmv", "flv", "mpg", "mpeg", "vob", "ogv", "m3u8"]
    static let subtitles: Set<String> = ["srt", "vtt", "ass", "ssa", "sub"]
    static func isVideo(_ name: String) -> Bool { video.contains((name as NSString).pathExtension.lowercased()) }
    static func title(_ filename: String) -> String {
        (filename as NSString).deletingPathExtension.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
    }
}
