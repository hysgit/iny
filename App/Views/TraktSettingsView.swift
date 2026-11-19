import SwiftUI

struct TraktSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage("traktScrobbling") private var enabled = false
    @State private var client = ""
    @State private var secret = ""
    @State private var code = ""
    @State private var verification: URL?
    @State private var message: String?
    @State private var polling: Task<Void, Never>?
    var body: some View {
        Form {
            TextField("Client ID", text: $client).textInputAutocapitalization(.never)
            SecureField("Client Secret", text: $secret)
            Button("连接 Trakt") { polling = Task { await connect() } }.disabled(client.isEmpty || secret.isEmpty)
            if !code.isEmpty { Text(code).font(.title.monospaced()).textSelection(.enabled) }
            if let verification { Link("在 Trakt 完成授权", destination: verification) }
            Toggle("同步观看进度", isOn: $enabled)
            Button("导入 Trakt 电影观看状态") { Task { await store.perform {
                let ids = try await TraktClient.shared.watchedMovies()
                for item in store.library.items where item.mediaType == "movie" && item.tmdbID.map(ids.contains) == true { try await store.update(item.id) { $0.watched = true } }
            } } }
            Button("退出 Trakt", role: .destructive) { polling?.cancel(); enabled = false; do { try KeychainVault.delete(account: "trakt"); message = "已退出。" } catch { message = error.localizedDescription } }
            if let message { Text(message) }
        }.navigationTitle("Trakt").onDisappear { polling?.cancel() }
    }
    private func connect() async {
        do {
            let value = try await TraktClient.shared.begin(client: client, secret: secret)
            guard let device = value["device_code"] as? String, let user = value["user_code"] as? String,
                  let url = value["verification_url"] as? String else { throw AppError.invalidResponse }
            code = user; verification = URL(string: url)
            let deadline = Date().addingTimeInterval(value["expires_in"] as? Double ?? 600)
            while Date() < deadline {
                try await Task.sleep(for: .seconds(value["interval"] as? Double ?? 5)); try Task.checkCancellation()
                if try await TraktClient.shared.poll(deviceCode: device) { enabled = true; code = ""; verification = nil; message = "Trakt 已连接。"; return }
            }
            message = "授权已过期，请重新连接。"
        } catch is CancellationError { } catch { message = error.localizedDescription }
    }
}
