import Foundation

extension AppStore {
    func importFolder(_ folder: URL) async throws {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() }; activity = nil }
        let files = try await Task.detached(priority: .utility) {
            guard let iterator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { throw AppError.message("无法读取所选文件夹。") }
            return iterator.compactMap { $0 as? URL }.filter { MediaFormats.isVideo($0.lastPathComponent) }
        }.value
        for (index, file) in files.enumerated() {
            try Task.checkCancellation(); activity = "导入 \(index + 1)/\(files.count)"
            let before = Set(library.items.map(\.id))
            _ = try await repository.importFile(file); try await refresh()
            guard let item = library.items.first(where: { !before.contains($0.id) }) else { continue }
            let parent = file.deletingLastPathComponent(); let stem = file.deletingPathExtension().lastPathComponent
            let nfo = parent.appendingPathComponent(stem + ".nfo")
            if FileManager.default.fileExists(atPath: nfo.path) {
                let value = try NFOMetadata.parse(Data(contentsOf: nfo))
                try await update(item.id) { value.apply(to: &$0) }
            }
            for name in [stem + ".jpg", stem + "-poster.jpg", "poster.jpg", "folder.jpg"] {
                let poster = parent.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: poster.path) { _ = try await repository.attachArtwork(poster, to: item.id); break }
            }
            let siblings = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
            if let subtitle = siblings.first(where: { MediaFormats.subtitles.contains($0.pathExtension.lowercased()) && $0.lastPathComponent.hasPrefix(stem + ".") }) {
                _ = try await repository.importSubtitle(subtitle, for: item.id)
            }
            try await refresh()
            if UserDefaults.standard.bool(forKey: "automaticMetadata"), item.tmdbID == nil { try await autoMatch(item.id) }
        }
    }

    func scan(_ source: MediaSource, root: String? = nil) async throws {
        defer { activity = nil }
        var pending: [String?] = [root]; var seen = Set<String>(); var batch: [MediaItem] = []; var count = 0
        while !pending.isEmpty {
            try Task.checkCancellation()
            let parent = pending.removeLast(); let key = parent ?? "__root__"
            guard seen.insert(key).inserted else { continue }
            for entry in try await entries(source, parent: parent) {
                if entry.isDirectory { if !seen.contains(entry.path) { pending.append(entry.path) }; continue }
                var item = MediaItem(title: entry.name, sourceID: source.id, remoteID: entry.id, remotePath: entry.path,
                                     posterURL: entry.posterURL, overview: entry.overview, year: entry.year, duration: entry.duration,
                                     position: entry.position, watched: entry.watched, mediaType: entry.mediaType)
                let filename = FilenameMetadata.parse(entry.name)
                item.season = filename.season; item.episode = filename.episode
                if filename.episode != nil { item.seriesTitle = filename.title; item.mediaType = "tv" }
                item.modifiedAt = Date(); batch.append(item); count += 1
                if batch.count >= 50 { _ = try await repository.addRemoteBatch(batch, sourceID: source.id); batch = []; try await refresh() }
            }
            activity = "扫描 \(source.name) · \(count) 部影片"
        }
        if !batch.isEmpty { _ = try await repository.addRemoteBatch(batch, sourceID: source.id) }
        try await refresh()
        if UserDefaults.standard.bool(forKey: "automaticMetadata") {
            for item in library.items where item.sourceID == source.id && item.tmdbID == nil { try Task.checkCancellation(); try await autoMatch(item.id) }
        }
    }

    func autoMatch(_ id: UUID) async throws {
        guard let item = library.items.first(where: { $0.id == id }),
              let token = try KeychainVault.read(String.self, account: "tmdb"), !token.isEmpty else { return }
        let client = MetadataClient(token: token)
        let query = item.seriesTitle ?? FilenameMetadata.parse(item.title).title
        let values = try await client.search(query)
        let type = item.mediaType == "tv" ? "tv" : "movie"
        let matches = values.filter { $0.media_type == type && (item.year == nil || $0.year == item.year) }
        guard let result = matches.first(where: { $0.displayTitle.compare(query, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) ?? (matches.count == 1 ? matches.first : nil) else { return }
        try await applyMetadata(result, to: item)
    }

    func applyMetadata(_ result: MetadataResult, to item: MediaItem) async throws {
        let token = try KeychainVault.read(String.self, account: "tmdb") ?? ""
        let details = try await MetadataClient(token: token).details(id: result.id, type: result.media_type ?? "movie")
        try await update(item.id) {
            details.apply(to: &$0); $0.posterURL = result.poster; $0.mediaType = result.media_type ?? "movie"
            if item.episode != nil { $0.title = item.title; $0.seriesTitle = result.displayTitle }
        }
    }
}
