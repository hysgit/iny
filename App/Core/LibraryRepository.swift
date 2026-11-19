import Foundation

actor LibraryRepository {
    let directory: URL
    private let index: URL
    private var snapshot: LibrarySnapshot?

    init(directory: URL) {
        self.directory = directory
        index = directory.appendingPathComponent("library.json")
    }

    func load() throws -> LibrarySnapshot {
        if let snapshot { return snapshot }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let result: LibrarySnapshot
        if FileManager.default.fileExists(atPath: index.path) {
            result = try JSONDecoder().decode(LibrarySnapshot.self, from: Data(contentsOf: index))
            guard result.version == 1 else { throw AppError.message("媒体库版本不受支持，原文件已保留。") }
        } else {
            result = LibrarySnapshot()
        }
        snapshot = result
        return result
    }

    // 同一 actor 内无 await 的读改写事务；写盘成功后才发布新快照。
    private func change(_ body: (inout LibrarySnapshot) throws -> Void) throws -> LibrarySnapshot {
        var next = try load()
        try body(&next)
        next.revision = (next.revision ?? 0) + 1
        let bytes = try JSONEncoder().encode(next)
        try bytes.write(to: index, options: .atomic)
        snapshot = next
        return next
    }

    func add(_ item: MediaItem) throws -> LibrarySnapshot {
        try change { state in
            if let sourceID = item.sourceID, !state.sources.contains(where: { $0.id == sourceID }) {
                throw AppError.message("影片来源已移除，请重新添加来源。")
            }
            if let sourceID = item.sourceID, let remoteID = item.remoteID,
               state.items.contains(where: { $0.sourceID == sourceID && $0.remoteID == remoteID }) { return }
            if let directURL = item.directURL, state.items.contains(where: { $0.directURL == directURL }) { return }
            state.items.append(item)
        }
    }

    func update(_ id: UUID, _ body: (inout MediaItem) -> Void) throws -> LibrarySnapshot {
        try change { state in
            guard let i = state.items.firstIndex(where: { $0.id == id }) else { return }
            body(&state.items[i])
            state.items[i].modifiedAt = Date()
        }
    }

    func addSource(_ source: MediaSource) throws -> LibrarySnapshot {
        try change { $0.sources.append(source) }
    }

    func remove(_ id: UUID) throws -> LibrarySnapshot {
        // 先提交索引再清理文件；清理失败最多留下孤立文件，不造成索引指向已删文件。
        let old = try load().items.first { $0.id == id }
        let next = try change { $0.items.removeAll { $0.id == id } }
        for filename in [old?.localFilename, old?.subtitleFilename, old?.posterFilename].compactMap({ $0 }) {
            if let url = try? localURL(filename) { try? FileManager.default.removeItem(at: url) }
        }
        return next
    }

    func removeSource(_ id: UUID) throws -> LibrarySnapshot {
        try change {
            $0.sources.removeAll { $0.id == id }
            $0.items.removeAll { $0.sourceID == id }
        }
    }

    func localURL(_ filename: String) throws -> URL {
        guard !filename.isEmpty, filename == (filename as NSString).lastPathComponent,
              filename != ".", filename != ".." else { throw AppError.message("文件路径无效。") }
        return directory.appendingPathComponent(filename)
    }

    func importFile(_ source: URL, title: String? = nil) async throws -> LibrarySnapshot {
        guard MediaFormats.isVideo(source.lastPathComponent) else { throw AppError.message("不支持此视频文件扩展名。") }
        _ = try load()
        let filename = UUID().uuidString + "." + source.pathExtension.lowercased()
        let target = try localURL(filename)
        do {
            try await Task.detached(priority: .utility) { try FileManager.default.copyItem(at: source, to: target) }.value
            let parsed = FilenameMetadata.parse(source.lastPathComponent)
            var item = MediaItem(title: title ?? parsed.title, localFilename: filename, year: parsed.year)
            item.season = parsed.season; item.episode = parsed.episode
            if parsed.episode != nil { item.mediaType = "tv"; item.seriesTitle = parsed.title }
            item.modifiedAt = Date()
            return try add(item)
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }

    func saveProgress(_ id: UUID, position: Double, duration: Double, capturedAt: Date) throws -> LibrarySnapshot {
        try change { state in
            guard let index = state.items.firstIndex(where: { $0.id == id }),
                  state.items[index].lastPlayedAt.map({ $0 <= capturedAt }) ?? true else { return }
            state.items[index].position = position
            if duration > 0 { state.items[index].duration = duration }
            state.items[index].lastPlayedAt = capturedAt; state.items[index].modifiedAt = capturedAt
            if duration > 0, position / duration >= 0.95 { state.items[index].watched = true }
        }
    }

    func attachArtwork(_ source: URL, to id: UUID) throws -> LibrarySnapshot {
        let name = UUID().uuidString + "." + source.pathExtension
        let target = try localURL(name)
        let previous = try load().items.first { $0.id == id }?.posterFilename
        guard try load().items.contains(where: { $0.id == id }) else { throw AppError.message("影片已移除。") }
        try FileManager.default.copyItem(at: source, to: target)
        do {
            let result = try update(id) { $0.posterFilename = name }
            if let previous { try? FileManager.default.removeItem(at: localURL(previous)) }
            return result
        } catch { try? FileManager.default.removeItem(at: target); throw error }
    }

    func addRemoteBatch(_ items: [MediaItem], sourceID: UUID) throws -> LibrarySnapshot {
        try change { state in
            guard state.sources.contains(where: { $0.id == sourceID }) else { throw AppError.message("来源已移除，扫描已停止。") }
            var known = Set(state.items.filter { $0.sourceID == sourceID }.compactMap(\.remoteID))
            for item in items where item.sourceID == sourceID {
                if let id = item.remoteID, known.insert(id).inserted { state.items.append(item) }
            }
        }
    }

    func importSubtitle(_ source: URL, for id: UUID) throws -> LibrarySnapshot {
        guard MediaFormats.subtitles.contains(source.pathExtension.lowercased()),
              try load().items.contains(where: { $0.id == id }) else { throw AppError.message("字幕格式或影片无效。") }
        let filename = UUID().uuidString + "." + source.pathExtension.lowercased()
        let target = try localURL(filename)
        let previous = try load().items.first { $0.id == id }?.subtitleFilename
        try FileManager.default.copyItem(at: source, to: target)
        do {
            let result = try update(id) { $0.subtitleFilename = filename }
            if let previous, let old = try? localURL(previous) { try? FileManager.default.removeItem(at: old) }
            return result
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }
}
