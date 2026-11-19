import SwiftUI

struct PlexAccountView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var verification: URL?
    @State private var code = ""
    @State private var servers: [PlexServer] = []
    @State private var error: String?
    @State private var connecting = false
    var body: some View {
        NavigationStack {
            List {
                if !code.isEmpty { Text(code).font(.title.monospaced()) }
                if let verification { Link("登录 Plex 账户", destination: verification) }
                if let error { Text(error).foregroundStyle(.red) }
                ForEach(servers) { server in
                    Section(server.name) {
                        ForEach(Array(server.connections.enumerated()), id: \.offset) { _, connection in
                            Button { Task { await connect(server, url: connection.url) } } label: {
                                VStack(alignment: .leading) { Text(connection.url.host ?? server.name); Text(connection.relay ? "中继连接" : "直接连接").font(.caption).foregroundStyle(.secondary) }
                            }.disabled(connecting)
                        }
                    }
                }
                if connecting { ProgressView("连接中…") }
            }.navigationTitle("Plex 账户").toolbar { Button("关闭") { dismiss() } }
            .task {
                do {
                    let pin = try await PlexAccount.begin(); code = pin.code; verification = pin.url
                    for _ in 0..<300 {
                        try await Task.sleep(for: .seconds(2)); try Task.checkCancellation()
                        if let token = try await PlexAccount.poll(id: pin.id, code: pin.code) {
                            servers = try await PlexAccount.servers(token: token); code = ""; verification = nil; return
                        }
                    }
                    error = "Plex 授权已过期。"
                } catch is CancellationError { } catch { self.error = error.localizedDescription }
            }
        }
    }
    private func connect(_ server: PlexServer, url: URL) async {
        connecting = true; defer { connecting = false }
        do { try await store.addSource(MediaSource(name: server.name, kind: .plex, endpoint: url), secret: SourceSecret(token: server.token)); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
