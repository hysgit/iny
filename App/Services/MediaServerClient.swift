import Foundation

private enum DeviceIdentity {
    static let value: String = {
        if let value = UserDefaults.standard.string(forKey: "mediaServerDeviceID") { return value }
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: "mediaServerDeviceID")
        return value
    }()
}

struct MediaServerClient {
    var source: MediaSource
    var secret: SourceSecret

    func request(_ path: String, query: [String: String] = [:], method: String = "GET", body: [String: Any]? = nil) throws -> URLRequest {
        var request = URLRequest(url: try URLTools.endpoint(source.endpoint, path, query: query))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if source.kind == .plex {
            request.setValue(secret.token, forHTTPHeaderField: "X-Plex-Token")
            request.setValue("Iny", forHTTPHeaderField: "X-Plex-Product")
            request.setValue(DeviceIdentity.value, forHTTPHeaderField: "X-Plex-Client-Identifier")
        } else {
            request.setValue("MediaBrowser Client=\"Iny\", Device=\"iOS\", DeviceId=\"\(DeviceIdentity.value)\", Version=\"0.1.0\"", forHTTPHeaderField: "Authorization")
            if !secret.token.isEmpty { request.setValue(secret.token, forHTTPHeaderField: "X-Emby-Token") }
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    func authenticate() async throws -> (MediaSource, SourceSecret) {
        if source.kind == .plex {
            guard !secret.token.isEmpty else { throw AppError.message("请填写你的 Plex 访问令牌。") }
            _ = try await HTTPClient.json(request("identity"))
            return (source, secret)
        }
        let result = try await HTTPClient.json(request("Users/AuthenticateByName", method: "POST", body: ["Username": source.username, "Pw": secret.password]))
        guard let token = result["AccessToken"] as? String,
              let user = result["User"] as? [String: Any], let id = user["Id"] as? String else { throw AppError.invalidResponse }
        var updated = source; updated.userID = id
        return (updated, SourceSecret(token: token))
    }

    func list(parent: String?) async throws -> [RemoteEntry] {
        if source.kind == .plex { return try await plexList(parent: parent) }
        guard let userID = source.userID else { throw AppError.message("请重新添加此服务器以登录。") }
        var result: [RemoteEntry] = []
        var offset = 0
        while true {
            try Task.checkCancellation()
            var query = ["Fields": "Overview,ProductionYear,RunTimeTicks", "Limit": "200", "StartIndex": String(offset),
                         "SortBy": "SortName", "SortOrder": "Ascending", "EnableUserData": "true"]
            if let parent { query["ParentId"] = parent }
            let response = try await HTTPClient.json(request("Users/\(userID)/Items", query: query))
            guard let items = response["Items"] as? [[String: Any]] else { throw AppError.invalidResponse }
            for value in items {
                guard let id = value["Id"] as? String, let name = value["Name"] as? String else { continue }
                let folder = value["IsFolder"] as? Bool ?? false
                guard folder || value["MediaType"] as? String == "Video" else { continue }
                let userData = value["UserData"] as? [String: Any] ?? [:]
                result.append(RemoteEntry(id: id, name: name, isDirectory: folder, path: id,
                                          overview: value["Overview"] as? String ?? "", year: value["ProductionYear"] as? Int,
                                          duration: (value["RunTimeTicks"] as? Double ?? 0) / 10_000_000,
                                          mediaType: value["Type"] as? String == "Episode" ? "tv" : "movie",
                                          position: (userData["PlaybackPositionTicks"] as? Double ?? 0) / 10_000_000,
                                          watched: userData["Played"] as? Bool ?? false))
            }
            offset += items.count
            let total = response["TotalRecordCount"] as? Int
            if items.isEmpty || (total.map { offset >= $0 } ?? (items.count < 200)) { break }
        }
        return result
    }

    private func plexList(parent: String?) async throws -> [RemoteEntry] {
        let path: String
        if let parent, parent.hasPrefix("section:") { path = "library/sections/\(parent.dropFirst(8))/all" }
        else if let parent { path = "library/metadata/\(parent)/children" }
        else { path = "library/sections" }
        var entries: [RemoteEntry] = []; var offset = 0
        while true {
            try Task.checkCancellation()
            let value = try await HTTPClient.json(request(path, query: ["X-Plex-Container-Start": String(offset), "X-Plex-Container-Size": "200"]))
            guard let container = value["MediaContainer"] as? [String: Any] else { throw AppError.invalidResponse }
            let values = (container["Metadata"] as? [[String: Any]]) ?? (container["Directory"] as? [[String: Any]]) ?? []
            for item in values {
                guard let title = item["title"] as? String, let key = (item["ratingKey"] as? String) ?? (item["key"] as? String) else { continue }
                let type = item["type"] as? String ?? ""
                let id = parent == nil ? "section:" + key : key
                entries.append(RemoteEntry(id: id, name: title, isDirectory: parent == nil || ["show", "season", "artist", "album"].contains(type), path: id,
                                           overview: item["summary"] as? String ?? "", year: item["year"] as? Int,
                                           duration: (item["duration"] as? Double ?? 0) / 1000, mediaType: type == "episode" ? "tv" : "movie",
                                           position: (item["viewOffset"] as? Double ?? 0) / 1000, watched: (item["viewCount"] as? Int ?? 0) > 0))
            }
            offset += values.count
            if values.isEmpty || offset >= (container["totalSize"] as? Int ?? offset) { break }
        }
        return entries
    }

    func playback(id: String) async throws -> PlaybackResource {
        if source.kind == .plex {
            let result = try await HTTPClient.json(request("library/metadata/\(id)"))
            guard let container = result["MediaContainer"] as? [String: Any],
                  let item = (container["Metadata"] as? [[String: Any]])?.first,
                  let media = (item["Media"] as? [[String: Any]])?.first,
                  let part = (media["Part"] as? [[String: Any]])?.first, let path = part["key"] as? String else { throw AppError.invalidResponse }
            return PlaybackResource(url: try URLTools.endpoint(source.endpoint, path, query: ["X-Plex-Token": secret.token]))
        }
        return PlaybackResource(url: try URLTools.endpoint(source.endpoint, "Videos/\(id)/stream", query: ["static": "true", "api_key": secret.token]))
    }

    func artwork(id: String) async throws -> Data {
        let path = source.kind == .plex ? "library/metadata/\(id)/thumb" : "Items/\(id)/Images/Primary"
        return try await HTTPClient.send(request(path, query: ["maxWidth": "500", "quality": "85"]))
    }

    func report(id: String, position: Double, stopped: Bool, paused: Bool = false) async throws {
        if source.kind == .plex {
            _ = try await HTTPClient.send(request(":/timeline", query: ["ratingKey": id, "key": "/library/metadata/\(id)",
                "state": stopped ? "stopped" : (paused ? "paused" : "playing"), "time": String(Int(position * 1000))]))
        } else {
            _ = try await HTTPClient.send(request("Sessions/Playing/" + (stopped ? "Stopped" : "Progress"), method: "POST",
                body: ["ItemId": id, "PositionTicks": Int64(position * 10_000_000), "IsPaused": paused]))
        }
    }

    func start(id: String, position: Double) async throws {
        guard source.kind != .plex else { return }
        _ = try await HTTPClient.send(request("Sessions/Playing", method: "POST", body: ["ItemId": id,
            "PositionTicks": Int64(position * 10_000_000), "PlayMethod": "DirectPlay", "CanSeek": true]))
    }
}
