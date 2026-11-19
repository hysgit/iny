import SwiftUI
import AVKit
#if canImport(MobileVLCKit)
import MobileVLCKit
#endif

struct PlayerScreen: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = PlayerModel()
    @State var item: MediaItem
    var queue: [MediaItem] = []
    @State private var settings = false
    @State private var scrub: Double = 0
    @State private var scrubbing = false
    @AppStorage("preferVLC") private var preferVLC = true
    @AppStorage("playbackSpeed") private var speed = 1.0
    @AppStorage("continuousPlayback") private var continuous = true

    var body: some View { PrivacyGate { playerContent } }

    private var playerContent: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if model.usesVLC {
                #if canImport(MobileVLCKit)
                VLCSurface(player: model.vlc).ignoresSafeArea()
                #endif
            } else { NativeSurface(player: model.native).ignoresSafeArea() }
            VStack {
                HStack {
                    Button { Task { await checkpoint(stopped: true); model.stop(); dismiss() } } label: { Image(systemName: "xmark.circle.fill").font(.title) }
                        .accessibilityLabel("关闭播放器").accessibilityIdentifier("player-close")
                    Text(item.title).font(.headline).lineLimit(1)
                    Spacer()
                    Button { settings = true } label: { Image(systemName: "slider.horizontal.3").font(.title2) }
                }.padding().background(.ultraThinMaterial)
                Spacer()
                if let error = model.error { Text(error).padding().background(.ultraThinMaterial).clipShape(RoundedRectangle(cornerRadius: 12)) }
                if model.buffering { ProgressView().tint(.white) }
                Spacer()
                if model.usesVLC {
                    VStack(spacing: 14) {
                        Slider(value: Binding(get: { scrubbing ? scrub : min(model.position, max(model.duration, 1)) }, set: { scrub = $0 }), in: 0...max(model.duration, 1)) { editing in
                            scrubbing = editing
                            if !editing { model.seek(scrub) }
                        }.disabled(model.duration <= 0).tint(.orange)
                        HStack {
                            Text(timestamp(model.position)).monospacedDigit()
                            Spacer()
                            Button { model.seek(model.position - 15) } label: { Image(systemName: "gobackward.15") }
                            Button { model.toggle() } label: { Image(systemName: model.playing ? "pause.fill" : "play.fill").font(.title) }.padding(.horizontal, 20)
                                .accessibilityIdentifier("playback-toggle").accessibilityLabel(model.playing ? "暂停" : "播放").accessibilityValue(model.playing ? "播放中" : "已暂停")
                            Button { model.seek(model.position + 15) } label: { Image(systemName: "goforward.15") }
                            Spacer()
                            Text(timestamp(model.duration)).monospacedDigit()
                        }.font(.title3)
                    }.padding().background(.ultraThinMaterial)
                }
            }.foregroundStyle(.white)
        }
        .interactiveDismissDisabled()
        .persistentSystemOverlays(.hidden)
        .task {
            await open()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { break }
                if model.error == nil, model.position > 0 { await checkpoint(stopped: false) }
            }
        }
        .onChange(of: model.finished) { _, finished in
            guard finished else { return }
            Task {
                await checkpoint(stopped: true)
                if continuous, let index = queue.firstIndex(where: { $0.id == item.id }), queue.indices.contains(index + 1) {
                    item = queue[index + 1]; await open()
                }
            }
        }
        .onDisappear { model.stop() }
        .sheet(isPresented: $settings) {
            PrivacyGate { NavigationStack {
                Form {
                    Section("播放速度") {
                        Picker("速度", selection: Binding(get: { Double(model.rate) }, set: { model.setRate(Float($0)) })) {
                            ForEach([0.5, 0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) { Text(String(format: "%.2g×", $0)).tag($0) }
                        }
                    }
                    if model.usesVLC {
                        Section("音轨") {
                            ForEach(model.audioTracks) { track in
                                Button { model.selectAudio(track.id) } label: { Label(track.name, systemImage: model.audioID == track.id ? "checkmark.circle.fill" : "circle") }
                            }
                        }
                        Section("字幕") {
                            Button("关闭字幕") { model.selectSubtitle(-1) }
                            ForEach(model.subtitleTracks) { track in
                                Button { model.selectSubtitle(track.id) } label: { Label(track.name, systemImage: model.subtitleID == track.id ? "checkmark.circle.fill" : "circle") }
                            }
                            Stepper("延迟 \(model.subtitleDelay, specifier: "%.1f") 秒", value: Binding(get: { model.subtitleDelay }, set: { model.setSubtitleDelay($0) }), in: -60...60, step: 0.1)
                        }
                        Section("章节") {
                            Button("上一章节") { model.chapter(next: false) }
                            Button("下一章节") { model.chapter(next: true) }
                        }
                    } else { Text("系统播放器的字幕、音轨、画中画和 AirPlay 可在播放控制栏中选择。") }
                }.navigationTitle("播放设置").toolbar { Button("完成") { settings = false } }
            }.presentationDetents([.medium, .large]) }
        }
    }

    private func open() async {
        do {
            let resource = try await store.resource(item)
            let subtitle: URL?
            if let filename = item.subtitleFilename { subtitle = try await store.repository.localURL(filename) } else { subtitle = nil }
            try model.open(resource, resume: item.watched ? 0 : item.position, subtitle: subtitle, preferVLC: preferVLC, speed: speed)
            await store.report(item, position: item.watched ? 0 : item.position, stopped: false, started: true)
        } catch { model.error = error.localizedDescription; model.buffering = false }
    }

    private func checkpoint(stopped: Bool) async {
        guard model.position > 0 || model.duration > 0 else { return }
        let position = model.position; let duration = model.duration
        await store.perform { try await store.progress(item, position: position, duration: duration) }
        await store.report(item, position: position, stopped: stopped, paused: !model.playing)
    }

    private func timestamp(_ seconds: Double) -> String {
        let value = Int(max(0, seconds))
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) : String(format: "%d:%02d", value / 60, value % 60)
    }
}

private struct NativeSurface: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player; controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) { controller.player = player }
}

#if canImport(MobileVLCKit)
private struct VLCSurface: UIViewRepresentable {
    let player: VLCMediaPlayer
    func makeUIView(context: Context) -> UIView {
        let view = UIView(); view.backgroundColor = .black; player.drawable = view; return view
    }
    func updateUIView(_ view: UIView, context: Context) { player.drawable = view }
    static func dismantleUIView(_ view: UIView, coordinator: ()) { }
}
#endif
