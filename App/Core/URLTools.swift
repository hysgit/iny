import Foundation

enum URLTools {
    static func server(_ text: String, smb: Bool = false) throws -> URL {
        guard let parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let url = parts.url, parts.host?.isEmpty == false,
              (smb ? ["smb"] : ["http", "https"]).contains(parts.scheme?.lowercased() ?? ""),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else { throw AppError.invalidURL }
        return url
    }

    static func endpoint(_ base: URL, _ path: String, query: [String: String] = [:]) throws -> URL {
        var url = base
        for segment in path.split(separator: "/") { url.appendPathComponent(String(segment)) }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw AppError.invalidURL }
        parts.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let result = parts.url else { throw AppError.invalidURL }
        return result
    }

    static func cleanStream(_ text: String) throws -> URL {
        let url = try server(text.components(separatedBy: "?")[0])
        guard let original = URLComponents(string: text), let items = original.queryItems else { return url }
        let blocked = ["token", "api_key", "access_token", "x-plex-token", "password", "authorization"]
        guard !items.contains(where: { blocked.contains($0.name.lowercased()) }) else {
            throw AppError.message("带登录令牌的链接请通过媒体服务器添加，避免将凭证写入媒体库。")
        }
        guard original.fragment == nil, let result = original.url else { throw AppError.invalidURL }
        return result
    }
}
