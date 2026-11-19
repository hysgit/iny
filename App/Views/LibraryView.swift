import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        Group {
            if store.loaded {
                TabView {
                    NavigationStack { LibraryView() }.tabItem { Label("媒体库", systemImage: "rectangle.stack.fill") }
                    NavigationStack { SourcesView() }.tabItem { Label("文件", systemImage: "folder.fill") }
                    NavigationStack { SettingsView() }.tabItem { Label("设置", systemImage: "gearshape.fill") }
                }
            } else {
                ContentUnavailableView {
                    Label("正在读取媒体库", systemImage: "externaldrive")
                } actions: { Button("重新读取") { Task { await store.load() } } }
            }
        }
        .alert("操作未完成", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("好", role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
        .safeAreaInset(edge: .bottom) {
            if let activity = store.activity { HStack { ProgressView(); Text(activity).font(.caption) }.padding(8).frame(maxWidth: .infinity).background(.regularMaterial) }
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject private var store: AppStore
    @State private var query = ""
    @State private var filter = "全部"
    @State private var importing = false
    @State private var stream = false
    @State private var playback: MediaItem?
    @AppStorage("librarySort") private var sort = "添加时间"
    private let columns = [GridItem(.adaptive(minimum: 130, maximum: 200), spacing: 18)]

    private var items: [MediaItem] {
        store.library.items.filter { item in
            (query.isEmpty || item.title.localizedCaseInsensitiveContains(query)) &&
            (filter == "全部" || filter == "本地" && item.isLocal || filter == "收藏" && item.favorite || filter == "未观看" && !item.watched)
        }.sorted { a, b in
            if sort == "片名" { return a.title.localizedStandardCompare(b.title) == .orderedAscending }
            if sort == "最近播放" { return (a.lastPlayedAt ?? .distantPast) > (b.lastPlayedAt ?? .distantPast) }
            return a.addedAt > b.addedAt
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if query.isEmpty, filter == "全部" {
                    let recent = store.library.items.filter { !$0.watched && $0.position > 0 }.sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
                    if !recent.isEmpty {
                        Text("继续观看").font(.title2.bold())
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(recent.prefix(12)) { item in
                                    Button { playback = item } label: {
                                        VStack(alignment: .leading, spacing: 8) {
                                            PosterArtwork(item: item).frame(width: 210, height: 118).clipped().clipShape(RoundedRectangle(cornerRadius: 12))
                                            ProgressView(value: item.progress).tint(.orange)
                                            Text(item.title).font(.subheadline.weight(.medium)).lineLimit(1)
                                        }.frame(width: 210)
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                Picker("筛选", selection: $filter) { ForEach(["全部", "本地", "收藏", "未观看"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
                if items.isEmpty {
                    ContentUnavailableView {
                        Label(query.isEmpty ? "添加你的第一部影片" : "没有匹配的影片", systemImage: "film.stack")
                    } description: { Text("导入视频，或在“文件”中连接 NAS 和媒体服务器。") } actions: {
                        Button("导入视频") { importing = true }.buttonStyle(.borderedProminent)
                    }.frame(maxWidth: .infinity).padding(.top, 40)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                        ForEach(items) { item in
                            NavigationLink { MediaDetailView(itemID: item.id) } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    ZStack(alignment: .topTrailing) {
                                        PosterArtwork(item: item).aspectRatio(2.0 / 3.0, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12))
                                        if item.watched { Image(systemName: "checkmark.circle.fill").foregroundStyle(.orange).padding(7) }
                                    }
                                    Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2).foregroundStyle(.primary)
                                    if let year = item.year { Text(String(year)).font(.caption).foregroundStyle(.secondary) }
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }.padding(20)
        }
        .background(Color(red: 0.045, green: 0.055, blue: 0.08))
        .navigationTitle("媒体库").searchable(text: $query, prompt: "搜索影片和剧集")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu { Picker("排序", selection: $sort) { ForEach(["添加时间", "片名", "最近播放"], id: \.self) { Text($0) } } } label: { Image(systemName: "arrow.up.arrow.down") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu { Button("导入视频", systemImage: "square.and.arrow.down") { importing = true }; Button("打开网络链接", systemImage: "link") { stream = true } } label: { Image(systemName: "plus") }
            }
        }
        .videoImporter(isPresented: $importing)
        .sheet(isPresented: $stream) { StreamForm() }
        .fullScreenCover(item: $playback) { item in PlayerScreen(item: item, queue: items) }
    }
}

struct PosterArtwork: View {
    @EnvironmentObject private var store: AppStore
    let item: MediaItem
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            Rectangle().fill(Color(red: 0.12, green: 0.15, blue: 0.20))
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { VStack(spacing: 12) { Image(systemName: item.mediaType == "tv" ? "tv" : "film").font(.largeTitle); Text(item.title).font(.headline).multilineTextAlignment(.center).lineLimit(3) }.foregroundStyle(.white.opacity(0.65)).padding(16) }
        }.clipped().accessibilityLabel(item.title)
        .task(id: item.posterURL?.absoluteString ?? item.id.uuidString) {
            if let data = await store.artwork(item) { image = UIImage(data: data) }
        }
    }
}

private struct VideoImporter: ViewModifier {
    @EnvironmentObject private var store: AppStore
    @Binding var isPresented: Bool
    func body(content: Content) -> some View {
        content.fileImporter(isPresented: $isPresented, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await store.importFiles(urls) }
            case .failure(let error): store.error = error.localizedDescription
            }
        }
    }
}

extension View {
    func videoImporter(isPresented: Binding<Bool>) -> some View { modifier(VideoImporter(isPresented: isPresented)) }
}

struct StreamForm: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var title = ""
    var body: some View {
        NavigationStack {
            Form { TextField("影片名称", text: $title); TextField("https://…", text: $url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled() }
                .navigationTitle("添加网络视频").toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("添加") { Task { await store.perform { try await store.addStream(url, title: title); dismiss() } } }.disabled(url.isEmpty) }
                }
        }
    }
}
