import SwiftUI
import UniformTypeIdentifiers

struct MediaDetailView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let itemID: UUID
    @State private var playback: MediaItem?
    @State private var subtitleImport = false
    @State private var metadata = false
    @State private var subtitles = false
    @State private var deleting = false
    private var item: MediaItem? { store.library.items.first { $0.id == itemID } }
    var body: some View {
        Group {
            if let item {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        HStack(alignment: .top, spacing: 24) {
                            PosterArtwork(item: item).frame(width: 140, height: 210).clipShape(RoundedRectangle(cornerRadius: 14))
                            VStack(alignment: .leading, spacing: 14) {
                                Text(item.title).font(.title2.bold())
                                if let year = item.year { Text(String(year)).foregroundStyle(.secondary) }
                                Text(item.isLocal ? "本地视频" : "网络视频").font(.caption).foregroundStyle(.secondary)
                                Button { playback = item } label: { Label(item.position > 0 && !item.watched ? "继续播放" : "播放", systemImage: "play.fill").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
                                if item.position > 0 { Button("从头播放") { var beginning = item; beginning.position = 0; playback = beginning }.font(.caption) }
                            }
                        }
                        if item.progress > 0 { ProgressView(value: item.progress).tint(.orange) }
                        if !item.overview.isEmpty { Text(item.overview).font(.body).foregroundStyle(.secondary).textSelection(.enabled) }
                        HStack(spacing: 16) {
                            Button { Task { await store.perform { try await store.update(item.id) { $0.favorite.toggle() } } } } label: { Label(item.favorite ? "已收藏" : "收藏", systemImage: item.favorite ? "heart.fill" : "heart") }
                            Button { Task { await store.perform { try await store.update(item.id) { $0.watched.toggle() } } } } label: { Label(item.watched ? "已观看" : "未观看", systemImage: item.watched ? "checkmark.circle.fill" : "circle") }
                        }.buttonStyle(.bordered)
                        VStack(spacing: 0) {
                            action("匹配海报与简介", icon: "sparkle.magnifyingglass") { metadata = true }
                            action(item.subtitleFilename == nil ? "导入字幕" : "替换外部字幕", icon: "captions.bubble") { subtitleImport = true }
                            action("查找在线字幕", icon: "text.magnifyingglass") { subtitles = true }
                            if !item.isLocal {
                                if let value = store.downloadProgress[item.id] {
                                    HStack { ProgressView(value: value); Button("取消下载") { store.cancelDownload(item.id) } }.padding()
                                } else { action("下载到本地", icon: "arrow.down.circle") { store.download(item) } }
                            }
                        }.background(.thinMaterial).clipShape(RoundedRectangle(cornerRadius: 16))
                    }.padding(24)
                }.navigationTitle("影片详情").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button(role: .destructive) { deleting = true } label: { Image(systemName: "trash") } }
                .fullScreenCover(item: $playback) { playing in PlayerScreen(item: playing, queue: store.library.items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }) }
                .sheet(isPresented: $metadata) { MetadataSearchView(item: item) }
                .sheet(isPresented: $subtitles) { SubtitleSearchView(item: item) }
                .fileImporter(isPresented: $subtitleImport, allowedContentTypes: [.data]) { result in
                    Task { await store.perform { try await store.attachSubtitle(result.get(), item: item) } }
                }
                .confirmationDialog(item.isLocal ? "删除影片及导入的视频文件？" : "从媒体库移除此影片？", isPresented: $deleting, titleVisibility: .visible) {
                    Button("删除", role: .destructive) { Task { await store.perform { try await store.remove(item); dismiss() } } }
                }
            } else { ContentUnavailableView("影片已移除", systemImage: "film") }
        }
    }
    private func action(_ title: String, icon: String, run: @escaping () -> Void) -> some View {
        Button(action: run) { HStack { Label(title, systemImage: icon); Spacer(); Image(systemName: "chevron.right").font(.caption) }.padding() }.foregroundStyle(.primary)
    }
}

struct MetadataSearchView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let item: MediaItem
    @State private var query = ""
    @State private var results: [MetadataResult] = []
    @State private var searching = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                HStack { TextField("片名", text: $query).onSubmit { Task { await search() } }; Button("搜索") { Task { await search() } }.disabled(searching) }
                if searching { ProgressView() }
                if let error { Text(error).foregroundStyle(.red) }
                ForEach(results) { result in
                    Button {
                        Task {
                            do {
                                try await store.update(item.id) {
                                    $0.title = result.displayTitle; $0.overview = result.overview ?? ""; $0.posterURL = result.poster
                                    $0.year = result.year; $0.tmdbID = result.id; $0.mediaType = result.media_type ?? "movie"
                                }; dismiss()
                            } catch { self.error = error.localizedDescription }
                        }
                    } label: {
                        HStack(spacing: 14) {
                            AsyncImage(url: result.poster) { image in image.resizable().scaledToFit() } placeholder: { Image(systemName: "film") }.frame(width: 50, height: 75)
                            VStack(alignment: .leading) { Text(result.displayTitle); Text(result.year.map(String.init) ?? "").font(.caption).foregroundStyle(.secondary); Text(result.overview ?? "").font(.caption).lineLimit(2) }
                        }
                    }
                }
            }.navigationTitle("匹配元数据").toolbar { Button("完成") { dismiss() } }
            .task { query = item.title; await search() }
        }
    }
    private func search() async {
        searching = true; error = nil
        defer { searching = false }
        do {
            guard let token = try KeychainVault.read(String.self, account: "tmdb"), !token.isEmpty else { throw AppError.message("请先在“设置 → 在线服务”填写自己的 TMDB Read Access Token。") }
            results = try await MetadataClient(token: token).search(query)
        } catch { self.error = error.localizedDescription }
    }
}

struct SubtitleSearchView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let item: MediaItem
    @State private var query = ""
    @State private var language = "zh-cn"
    @State private var results: [SubtitleResult] = []
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                TextField("片名", text: $query)
                Picker("语言", selection: $language) { Text("简体中文").tag("zh-cn"); Text("繁体中文").tag("zh-tw"); Text("英语").tag("en") }
                Button("搜索字幕") { Task { await search() } }.disabled(busy)
                if busy { ProgressView() }
                if let error { Text(error).foregroundStyle(.red) }
                ForEach(results) { result in
                    Button {
                        Task {
                            busy = true; error = nil; defer { busy = false }
                            do {
                                let file = try await client().download(result.id)
                                defer { try? FileManager.default.removeItem(at: file) }
                                try await store.attachSubtitle(file, item: item); dismiss()
                            } catch { self.error = error.localizedDescription }
                        }
                    } label: { VStack(alignment: .leading, spacing: 5) { Text(result.name); Text("\(result.language) · \(result.downloads) 次下载").font(.caption).foregroundStyle(.secondary) } }.disabled(busy)
                }
            }.navigationTitle("在线字幕").toolbar { Button("完成") { dismiss() } }
            .task { query = item.title }
        }
    }
    private func client() throws -> OpenSubtitlesClient {
        guard let key = try KeychainVault.read(String.self, account: "opensubtitles-key"), !key.isEmpty,
              let token = try KeychainVault.read(String.self, account: "opensubtitles-token"), !token.isEmpty else { throw AppError.message("请先在“设置 → 在线服务”配置 OpenSubtitles API Key 并登录。") }
        return OpenSubtitlesClient(apiKey: key, token: token)
    }
    private func search() async {
        busy = true; error = nil; defer { busy = false }
        do { results = try await client().search(title: query, language: language) }
        catch { self.error = error.localizedDescription }
    }
}
