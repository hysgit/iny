import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage("preferVLC") private var preferVLC = true
    @AppStorage("continuousPlayback") private var continuous = true
    @AppStorage("playbackSpeed") private var speed = 1.0
    @AppStorage("privacyLock") private var privacyLock = false
    @AppStorage("automaticMetadata") private var automaticMetadata = false
    @AppStorage("serverTranscoding") private var transcoding = false
    @AppStorage("cloudLibrarySync") private var cloudSync = false
    @State private var exporting = false
    @State private var document = LibraryExport(data: Data())
    var body: some View {
        Form {
            Section("播放") {
                Toggle("优先使用 VLC", isOn: $preferVLC)
                Toggle("连续播放", isOn: $continuous)
                Toggle("使用媒体服务器兼容转码", isOn: $transcoding)
                NavigationLink("字幕样式与字体") { SubtitleStyleView() }
                Picker("默认速度", selection: $speed) { ForEach([0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { Text(String(format: "%.2g×", $0)).tag($0) } }
                Text("VLC 用于 MKV、外部字幕和认证共享；系统播放器提供原生画中画及 AirPlay。编码支持以设备实测为准。").font(.footnote).foregroundStyle(.secondary)
            }
            Section("服务") { NavigationLink("在线服务") { ServiceSettingsView() }; NavigationLink("Trakt") { TraktSettingsView() } }
            Section("隐私") { Toggle("使用设备密码或 Face ID 解锁", isOn: $privacyLock) }
            Section("媒体库") {
                Toggle("iCloud 媒体库与进度同步", isOn: $cloudSync)
                if cloudSync { Button("立即同步 iCloud") { Task { await store.synchronizeCloud() } } }
                Toggle("自动匹配在线元数据", isOn: $automaticMetadata)
                LabeledContent("影片数量", value: String(store.library.items.count))
                LabeledContent("来源数量", value: String(store.library.sources.count))
                Button("导出媒体库索引") {
                    do { document = LibraryExport(data: try JSONEncoder().encode(store.library)); exporting = true }
                    catch { store.error = error.localizedDescription }
                }
                Text("索引不包含视频文件和登录凭证。").font(.footnote).foregroundStyle(.secondary)
            }
            Section("关于") {
                LabeledContent("Iny", value: "0.1.0")
                Text("你的本地视频与家庭媒体库。").font(.footnote).foregroundStyle(.secondary)
                NavigationLink("开源组件") { OpenSourceView() }
                Link("VLC 开源许可", destination: URL(string: "https://www.videolan.org/vlc/libvlc.html")!)
                Link("TMDB", destination: URL(string: "https://www.themoviedb.org")!)
            }
        }.navigationTitle("设置")
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "media-library") { result in
            if case .failure(let error) = result { store.error = error.localizedDescription }
        }
    }
}

private struct OpenSourceView: View {
    var body: some View {
        ScrollView {
            Text(license).font(.caption.monospaced()).textSelection(.enabled).padding()
        }.navigationTitle("开源组件")
    }
    private var license: String {
        guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "MobileVLCKit 与 AMSMB2 使用 LGPL 2.1 许可。" }
        return text
    }
}

private struct LibraryExport: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct ServiceSettingsView: View {
    @State private var tmdb = ""
    @State private var subtitleKey = ""
    @State private var username = ""
    @State private var password = ""
    @State private var message: String?
    @State private var busy = false
    var body: some View {
        Form {
            Section("TMDB") {
                SecureField("Read Access Token", text: $tmdb)
                Button("保存 TMDB 配置") {
                    do { try KeychainVault.save(tmdb, account: "tmdb"); message = "TMDB 配置已保存。" }
                    catch { message = error.localizedDescription }
                }
                Link("获取自己的 TMDB API 凭证", destination: URL(string: "https://www.themoviedb.org/settings/api")!)
                Text("This product uses the TMDB API but is not endorsed or certified by TMDB.").font(.caption).foregroundStyle(.secondary)
            }
            Section("OpenSubtitles") {
                SecureField("API Key", text: $subtitleKey)
                TextField("用户名", text: $username)
                SecureField("密码", text: $password)
                Button("登录 OpenSubtitles") {
                    Task {
                        busy = true; message = nil; defer { busy = false }
                        do {
                            let token = try await OpenSubtitlesClient(apiKey: subtitleKey, token: "").login(username: username, password: password)
                            try KeychainVault.save(subtitleKey, account: "opensubtitles-key")
                            try KeychainVault.save(token, account: "opensubtitles-token")
                            password = ""; message = "OpenSubtitles 已登录。"
                        } catch { message = error.localizedDescription }
                    }
                }.disabled(busy || subtitleKey.isEmpty || username.isEmpty || password.isEmpty)
                Link("OpenSubtitles 开发者设置", destination: URL(string: "https://www.opensubtitles.com/consumers")!)
            }
            if busy { ProgressView() }
            if let message { Text(message) }
        }.textInputAutocapitalization(.never).autocorrectionDisabled().navigationTitle("在线服务")
        .task {
            do { tmdb = try KeychainVault.read(String.self, account: "tmdb") ?? ""; subtitleKey = try KeychainVault.read(String.self, account: "opensubtitles-key") ?? "" }
            catch { message = error.localizedDescription }
        }
    }
}
