import SwiftUI

@main
struct InyApp: App {
    @StateObject private var store = AppStore()
    var body: some Scene {
        WindowGroup {
            PrivacyGate { RootView() }.environmentObject(store).preferredColorScheme(.dark).tint(.orange)
                .task { do { try FontLibrary.registerAll() } catch { store.error = error.localizedDescription }; await store.load() }
                .onOpenURL { url in
                    if url.isFileURL { Task { await store.importFiles([url]) } }
                    else if url.scheme == "iny", let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                            let stream = parts.queryItems?.first(where: { $0.name == "url" })?.value {
                        Task { await store.perform { try await store.addStream(stream, title: "") } }
                    }
                }
        }
    }
}
