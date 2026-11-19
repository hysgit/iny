import SwiftUI
import UniformTypeIdentifiers

struct SourcesView: View {
    @EnvironmentObject private var store: AppStore
    @State private var adding = false
    @State private var importing = false
    @State private var folderImport = false
    @State private var deleting: MediaSource?
    var body: some View {
        List {
            Section {
                Button("导入视频", systemImage: "iphone.and.arrow.forward") { importing = true }
                Button("导入整个文件夹", systemImage: "folder.badge.plus") { folderImport = true }
                NavigationLink { LocalFilesView() } label: { Label("本地视频", systemImage: "internaldrive") }
            }
            Section("网络共享与媒体服务器") {
                ForEach(store.library.sources) { source in
                    NavigationLink { SourceBrowser(source: source, title: source.name) } label: {
                        HStack(spacing: 14) {
                            Image(systemName: source.kind == .smb || source.kind == .webdav ? "externaldrive.connected.to.line.below" : "server.rack").font(.title2).foregroundStyle(.orange).frame(width: 36)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(source.name).font(.headline)
                                Text(source.kind.title + " · " + (source.endpoint.host ?? "")).font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 5)
                    }.swipeActions { Button("删除", role: .destructive) { deleting = source } }
                }
                Button("添加来源", systemImage: "plus.circle.fill") { adding = true }
            }
            Section {
                Text("也可从 iOS“文件”中的 iCloud Drive、第三方云盘或 SMB 位置选择视频并导入。").font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("文件")
        .sheet(isPresented: $adding) { PrivacyGate { SourceForm() } }
        .videoImporter(isPresented: $importing)
        .fileImporter(isPresented: $folderImport, allowedContentTypes: [.folder]) { result in
            Task { await store.perform { try await store.importFolder(result.get()) } }
        }
        .confirmationDialog("删除此来源及其媒体库记录？本地导入的视频会保留。", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("删除来源", role: .destructive) { if let source = deleting { Task { await store.perform { try await store.removeSource(source) } } }; deleting = nil }
        }
    }
}

private struct LocalFilesView: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        List(store.library.items.filter(\.isLocal)) { item in
            NavigationLink { MediaDetailView(itemID: item.id) } label: { Label(item.title, systemImage: "film") }
        }.navigationTitle("本地视频")
    }
}

struct SourceBrowser: View {
    @EnvironmentObject private var store: AppStore
    let source: MediaSource
    var parent: String?
    var title: String
    @State private var entries: [RemoteEntry] = []
    @State private var loading = true
    @State private var error: String?
    @State private var query = ""
    @State private var playback: MediaItem?
    @State private var importing = false
    @State private var added = 0
    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red); Button("重试") { Task { await load() } } }
            if loading { ProgressView("正在连接…") }
            ForEach(entries.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { entry in
                if entry.isDirectory {
                    NavigationLink { SourceBrowser(source: source, parent: entry.path, title: entry.name) } label: { Label(entry.name, systemImage: "folder.fill").padding(.vertical, 4) }
                } else {
                    Button {
                        Task { await store.perform { playback = try await store.addEntry(entry, source: source) } }
                    } label: { Label(entry.name, systemImage: "play.rectangle").foregroundStyle(.primary).padding(.vertical, 4) }
                    .contextMenu {
                        Button("加入媒体库", systemImage: "plus") { Task { await store.perform { _ = try await store.addEntry(entry, source: source) } } }
                    }
                }
            }
            if !loading && entries.isEmpty && error == nil { Text("这个文件夹中没有视频。").foregroundStyle(.secondary) }
        }.navigationTitle(title).searchable(text: $query, prompt: "搜索此文件夹")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("扫描全部子文件夹") { Task { await store.perform { try await store.scan(source, root: parent) } } }.disabled(store.activity != nil)
                Button(importing ? "已加入 \(added)" : "加入当前文件夹") {
                    Task {
                        importing = true; added = 0
                        defer { importing = false }
                        for entry in entries where !entry.isDirectory {
                            await store.perform { _ = try await store.addEntry(entry, source: source); added += 1 }
                        }
                    }
                }.disabled(importing || loading || entries.isEmpty)
            }
        }
        .task { await load() }.refreshable { await load() }
        .fullScreenCover(item: $playback) { item in PlayerScreen(item: item) }
    }
    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do { entries = try await store.entries(source, parent: parent) }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}

struct SourceForm: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var kind: SourceKind = .webdav
    @State private var name = ""
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var share = ""
    @State private var hostKey = ""
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var redirect = "iny://oauth"
    @State private var authorizedSecret: SourceSecret?
    @State private var authorization: CloudOAuth?
    @State private var saving = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Picker("类型", selection: $kind) { ForEach(SourceKind.allCases) { Text($0.title).tag($0) } }
                TextField("名称", text: $name)
                if kind.isCloud {
                    Section("云盘授权") {
                        TextField("OAuth Client ID", text: $clientID)
                        SecureField("Client Secret（需要时填写）", text: $clientSecret)
                        TextField("回调地址", text: $redirect)
                        Button("登录 \(kind.title)") { Task { await authorize() } }.disabled(saving || clientID.isEmpty)
                    }
                } else { TextField(kind == .smb ? "smb://192.168.1.10" : "https://nas.example.com:8096", text: $address).keyboardType(.URL) }
                if kind == .smb || kind == .nfs { TextField(kind == .nfs ? "导出路径，例如 /volume1/video" : "共享名称，例如 Movies", text: $share) }
                if kind == .sftp { TextField("OpenSSH 主机公钥", text: $hostKey) }
                if kind != .plex { TextField("用户名", text: $username) }
                SecureField(kind.isCloud ? "Access Token（也可直接填写）" : (kind == .plex ? "Plex 访问令牌" : "密码"), text: $password)
                if kind == .plex { Text("填写自己的 Plex Media Server 地址与访问令牌。当前使用服务器直连。").font(.footnote).foregroundStyle(.secondary) }
                if let error { Text(error).foregroundStyle(.red) }
                if saving { ProgressView("验证连接中…") }
            }.textInputAutocapitalization(.never).autocorrectionDisabled()
            .navigationTitle("添加来源").toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) { Button("连接") { Task { await save() } }.disabled((address.isEmpty && !kind.isCloud) || saving) }
            }.interactiveDismissDisabled(saving)
            .onChange(of: kind) { _, _ in password = ""; authorizedSecret = nil }
        }
    }
    private func save() async {
        saving = true; error = nil
        defer { saving = false }
        do {
            let scheme = [.ftp, .sftp, .nfs].contains(kind) ? kind.rawValue : nil
            let url = try kind.isCloud ? CloudDriveClient.endpoint(kind) : URLTools.server(address, smb: kind == .smb, scheme: scheme)
            if kind == .smb, share.contains("/") || share.isEmpty { throw AppError.message("共享名称不能为空，且不能包含斜线。") }
            let source = MediaSource(name: name.isEmpty ? kind.title : name, kind: kind, endpoint: url, username: username, share: share, hostKey: hostKey.isEmpty ? nil : hostKey)
            let secret = authorizedSecret ?? SourceSecret(password: kind == .plex || kind.isCloud ? "" : password, token: kind == .plex || kind.isCloud ? password : "")
            try await store.addSource(source, secret: secret)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
    private func authorize() async {
        saving = true; error = nil; defer { saving = false }
        do {
            let flow = CloudOAuth(); authorization = flow
            let value = try await flow.signIn(kind: kind, clientID: clientID, clientSecret: clientSecret, redirect: redirect)
            authorizedSecret = value; password = value.token
        } catch { self.error = error.localizedDescription }
    }
}
