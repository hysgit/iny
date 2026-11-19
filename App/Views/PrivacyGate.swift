import SwiftUI
import LocalAuthentication

struct PrivacyGate<Content: View>: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("privacyLock") private var enabled = false
    @State private var locked = true
    @State private var authenticating = false
    @State private var error: String?
    @ViewBuilder var content: Content
    var body: some View {
        ZStack {
            content.privacySensitive().allowsHitTesting(!enabled || !locked)
            if enabled && locked {
                Color.black.ignoresSafeArea()
                VStack(spacing: 24) {
                    Image(systemName: "lock.shield").font(.system(size: 60)).foregroundStyle(.orange)
                    Button("解锁媒体库") { Task { await unlock() } }.buttonStyle(.borderedProminent).disabled(authenticating)
                    if let error { Text(error).font(.footnote).multilineTextAlignment(.center).padding() }
                }
            }
        }.task { if enabled { await unlock() } }
        .onChange(of: enabled) { _, enabled in if enabled { locked = true; Task { await unlock() } } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { locked = true }
            if phase == .active && enabled && locked { Task { await unlock() } }
        }
    }
    private func unlock() async {
        guard !authenticating else { return }
        authenticating = true; error = nil; defer { authenticating = false }
        do {
            let context = LAContext()
            let success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "解锁你的媒体库")
            if success { locked = false }
        } catch { self.error = error.localizedDescription }
    }
}
