import Foundation

struct PlexServer: Identifiable {
    var id: String
    var name: String
    var token: String
    var connections: [(url: URL, relay: Bool)]
}

enum PlexAccount {
    static func request(_ path: String, token: String? = nil) throws -> URLRequest {
        var request = URLRequest(url: try URLTools.endpoint(URL(string: "https://plex.tv/api/v2")!, path))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Iny", forHTTPHeaderField: "X-Plex-Product")
        request.setValue(DeviceIdentity.value, forHTTPHeaderField: "X-Plex-Client-Identifier")
        if let token { request.setValue(token, forHTTPHeaderField: "X-Plex-Token") }
        return request
    }
    static func begin() async throws -> (id: Int, code: String, url: URL) {
        var request = try request("pins"); request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type"); request.httpBody = Data("strong=true".utf8)
        let json = try await HTTPClient.json(request)
        guard let id = json["id"] as? Int, let code = json["code"] as? String else { throw AppError.invalidResponse }
        var auth = URLComponents(string: "https://app.plex.tv/auth")!
        var fragment = URLComponents(); fragment.queryItems = [URLQueryItem(name: "clientID", value: DeviceIdentity.value), URLQueryItem(name: "code", value: code), URLQueryItem(name: "context[device][product]", value: "Iny")]
        auth.percentEncodedFragment = "?" + (fragment.percentEncodedQuery ?? "")
        return (id, code, auth.url!)
    }
    static func poll(id: Int, code: String) async throws -> String? {
        var request = try request("pins/\(id)")
        var parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "code", value: code)]; request.url = parts.url
        return try await HTTPClient.json(request)["authToken"] as? String
    }
    static func servers(token: String) async throws -> [PlexServer] {
        var request = try request("resources", token: token)
        var parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "includeHttps", value: "1"), URLQueryItem(name: "includeRelay", value: "1")]; request.url = parts.url
        let data = try await HTTPClient.send(request)
        guard let devices = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw AppError.invalidResponse }
        return devices.compactMap { device in
            guard (device["provides"] as? String)?.contains("server") == true,
                  let id = device["clientIdentifier"] as? String, let name = device["name"] as? String else { return nil }
            let rows = device["connections"] as? [[String: Any]] ?? []
            let connections: [(URL, Bool)] = rows.compactMap { row in
                guard let text = row["uri"] as? String, let url = URL(string: text), ["http", "https"].contains(url.scheme ?? "") else { return nil }
                return (url, row["relay"] as? Bool ?? false)
            }
            return PlexServer(id: id, name: name, token: device["accessToken"] as? String ?? token, connections: connections)
        }
    }
}
