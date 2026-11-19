import Foundation

struct MetadataResult: Identifiable, Decodable, Hashable {
    let id: Int
    let title: String?
    let name: String?
    let overview: String?
    let poster_path: String?
    let release_date: String?
    let first_air_date: String?
    let media_type: String?
    var displayTitle: String { title ?? name ?? "未命名" }
    var year: Int? { (release_date ?? first_air_date).flatMap { Int($0.prefix(4)) } }
    var poster: URL? { poster_path.flatMap { URL(string: "https://image.tmdb.org/t/p/w500" + $0) } }
}

struct MetadataClient {
    let token: String
    func search(_ query: String) async throws -> [MetadataResult] {
        let url = try URLTools.endpoint(URL(string: "https://api.themoviedb.org/3")!, "search/multi", query: ["query": query, "language": "zh-CN", "include_adult": "false"])
        var request = URLRequest(url: url)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        struct Response: Decodable { let results: [MetadataResult] }
        return try JSONDecoder().decode(Response.self, from: await HTTPClient.send(request)).results.filter { ["movie", "tv"].contains($0.media_type ?? "") }
    }
}

struct SubtitleResult: Identifiable {
    let id: Int
    let name: String
    let language: String
    let downloads: Int
}

struct OpenSubtitlesClient {
    let apiKey: String
    let token: String
    private static let base = URL(string: "https://api.opensubtitles.com/api/v1")!

    private func request(_ path: String, query: [String: String] = [:]) throws -> URLRequest {
        var request = URLRequest(url: try URLTools.endpoint(Self.base, path, query: query))
        request.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        request.setValue("Iny v0.1.0", forHTTPHeaderField: "User-Agent")
        if !token.isEmpty { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        return request
    }

    func login(username: String, password: String) async throws -> String {
        var request = try request("login")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["username": username, "password": password])
        let response = try await HTTPClient.json(request)
        guard let token = response["token"] as? String else { throw AppError.invalidResponse }
        return token
    }

    func search(title: String, language: String) async throws -> [SubtitleResult] {
        let response = try await HTTPClient.json(request("subtitles", query: ["query": title, "languages": language]))
        guard let rows = response["data"] as? [[String: Any]] else { throw AppError.invalidResponse }
        return rows.flatMap { row -> [SubtitleResult] in
            guard let attrs = row["attributes"] as? [String: Any], let files = attrs["files"] as? [[String: Any]] else { return [] }
            return files.compactMap { file in
                guard let id = file["file_id"] as? Int else { return nil }
                return SubtitleResult(id: id, name: file["file_name"] as? String ?? attrs["release"] as? String ?? "字幕",
                                      language: attrs["language"] as? String ?? "", downloads: attrs["download_count"] as? Int ?? 0)
            }
        }
    }

    func download(_ id: Int) async throws -> URL {
        var request = try request("download")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["file_id": id, "sub_format": "srt"])
        let response = try await HTTPClient.json(request)
        guard let link = response["link"] as? String, let url = URL(string: link), url.scheme == "https" else { throw AppError.invalidResponse }
        let (temporary, responseData) = try await HTTPClient.session.download(from: url)
        guard let response = responseData as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw AppError.invalidResponse }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".srt")
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }
}
