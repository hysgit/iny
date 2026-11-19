import Foundation

actor TraktClient {
    static let shared = TraktClient()
    private let base = URL(string: "https://api.trakt.tv")!
    private var refreshing: Task<SourceSecret, Error>?
    private var episodes: [UUID: Int] = [:]
    private func request(_ path: String, query: [String: String] = [:], body: [String: Any]? = nil, credential: SourceSecret) throws -> URLRequest {
        var request = URLRequest(url: try URLTools.endpoint(base, path, query: query))
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        request.setValue(credential.clientID ?? "", forHTTPHeaderField: "trakt-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !credential.token.isEmpty { request.setValue("Bearer " + credential.token, forHTTPHeaderField: "Authorization") }
        if let body { request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        return request
    }
    func begin(client: String, secret: String) async throws -> [String: Any] {
        let credential = SourceSecret(clientID: client, clientSecret: secret)
        try KeychainVault.save(credential, account: "trakt")
        return try await HTTPClient.json(request("oauth/device/code", body: ["client_id": client], credential: credential))
    }
    func poll(deviceCode: String) async throws -> Bool {
        guard let seed = try KeychainVault.read(SourceSecret.self, account: "trakt") else { throw AppError.message("Trakt 配置已移除。") }
        let request = try request("oauth/device/token", body: ["code": deviceCode, "client_id": seed.clientID ?? "", "client_secret": seed.clientSecret ?? ""], credential: seed)
        let (data, response) = try await HTTPClient.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 400 { return false }
        guard status == 200 else { throw AppError.http(status) }
        try saveToken(data, previous: seed); return true
    }
    private func saveToken(_ data: Data, previous: SourceSecret) throws {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let token = json["access_token"] as? String else { throw AppError.invalidResponse }
        var secret = previous; secret.token = token; secret.refreshToken = json["refresh_token"] as? String ?? previous.refreshToken
        secret.expiresAt = (json["expires_in"] as? Double).map { Date().addingTimeInterval($0) }
        try KeychainVault.save(secret, account: "trakt")
    }
    private func credential() async throws -> SourceSecret {
        guard let secret = try KeychainVault.read(SourceSecret.self, account: "trakt"), !secret.token.isEmpty else { throw AppError.message("请先连接 Trakt。") }
        guard secret.expiresAt.map({ $0.timeIntervalSinceNow < 120 }) == true, let refresh = secret.refreshToken else { return secret }
        if let refreshing { return try await refreshing.value }
        let task = Task {
            let data = try await HTTPClient.send(request("oauth/token", body: ["refresh_token": refresh, "client_id": secret.clientID ?? "", "client_secret": secret.clientSecret ?? "", "grant_type": "refresh_token", "redirect_uri": "urn:ietf:wg:oauth:2.0:oob"], credential: secret))
            guard try KeychainVault.read(SourceSecret.self, account: "trakt")?.refreshToken == refresh else { throw CancellationError() }
            try saveToken(data, previous: secret)
            return try KeychainVault.read(SourceSecret.self, account: "trakt")!
        }
        refreshing = task; defer { refreshing = nil }; return try await task.value
    }
    private func rows(_ path: String, query: [String: String] = [:], credential: SourceSecret) async throws -> [[String: Any]] {
        let data = try await HTTPClient.send(request(path, query: query, credential: credential))
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw AppError.invalidResponse }; return rows
    }
    func scrobble(_ item: MediaItem, position: Double, duration: Double, action: String) async throws {
        guard duration > 0, let id = item.tmdbID else { return }
        let credential = try await credential(); var body: [String: Any] = ["progress": min(100, max(0, position / duration * 100)), "app_version": "0.2.0"]
        if item.mediaType == "tv" {
            guard let season = item.season, let episode = item.episode else { return }
            if episodes[item.id] == nil {
                let shows = try await rows("search/tmdb/\(id)", query: ["type": "show"], credential: credential)
                guard let show = shows.first?["show"] as? [String: Any], let ids = show["ids"] as? [String: Any], let showID = ids["trakt"] as? Int else { return }
                let result = try await HTTPClient.json(request("shows/\(showID)/seasons/\(season)/episodes/\(episode)", credential: credential))
                episodes[item.id] = (result["ids"] as? [String: Any])?["trakt"] as? Int
            }
            guard let episodeID = episodes[item.id] else { return }; body["episode"] = ["ids": ["trakt": episodeID]]
        } else { body["movie"] = ["ids": ["tmdb": id]] }
        _ = try await HTTPClient.send(request("scrobble/\(action)", body: body, credential: credential))
    }
    func watchedMovies() async throws -> Set<Int> {
        let credential = try await credential()
        return Set(try await rows("sync/watched/movies", credential: credential).compactMap { (($0["movie"] as? [String: Any])?["ids"] as? [String: Any])?["tmdb"] as? Int })
    }
    func rate(_ item: MediaItem, rating: Int) async throws {
        guard let id = item.tmdbID, item.mediaType == "movie", (1...10).contains(rating) else { throw AppError.message("请先匹配电影元数据。") }
        let credential = try await credential()
        _ = try await HTTPClient.send(request("sync/ratings", body: ["movies": [["ids": ["tmdb": id], "rating": rating]]], credential: credential))
    }
}
