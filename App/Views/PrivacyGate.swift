import SwiftUI
import LocalAuthentication

@MainActor
final class PrivacyState: ObservableObject {
    static let shared = PrivacyState()
    @Published var locked = true
    @Published var authenticating = false
    @Published var error: String?

    func unlock() async {
        guard !authenticating else { return }
        authenticating = true; error = nil; defer { authenticating = false }
        do {
            let context = LAContext()
            let success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "解锁你的媒体库")
            if success { locked = false }
        } catch { self.error = error.localizedDescription }
    }
}

struct PrivacyGate<Content: View>: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("privacyLock") private var enabled = false
    @ObservedObject private var privacy = PrivacyState.shared
    @ViewBuilder var content: Content
    var body: some View {
        ZStack {
            content.privacySensitive().allowsHitTesting(!enabled || !privacy.locked).accessibilityHidden(enabled && privacy.locked)
            if enabled && privacy.locked {
                Color.black.ignoresSafeArea()
                VStack(spacing: 24) {
                    Image(systemName: "lock.shield").font(.system(size: 60)).foregroundStyle(.orange)
                    Button("解锁媒体库") { Task { await privacy.unlock() } }.buttonStyle(.borderedProminent).disabled(privacy.authenticating)
                    if let error = privacy.error { Text(error).font(.footnote).multilineTextAlignment(.center).padding() }
                }
            }
        }.task { if enabled && privacy.locked { await privacy.unlock() } }
        .onChange(of: enabled) { _, enabled in if enabled { privacy.locked = true; Task { await privacy.unlock() } } }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { privacy.locked = true }
            if phase == .active && enabled && privacy.locked { Task { await privacy.unlock() } }
        }
    }
}
