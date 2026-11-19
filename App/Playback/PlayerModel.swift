import Foundation
import AVKit
import Combine
#if canImport(MobileVLCKit)
import MobileVLCKit
#endif

struct PlaybackTrack: Identifiable {
    let id: Int32
    let name: String
}

@MainActor
final class PlayerModel: ObservableObject {
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var playing = false
    @Published var buffering = false
    @Published var finished = false
    @Published var error: String?
    @Published var rate: Float = 1
    @Published var audioTracks: [PlaybackTrack] = []
    @Published var subtitleTracks: [PlaybackTrack] = []
    @Published var audioID: Int32 = -1
    @Published var subtitleID: Int32 = -1
    @Published var subtitleDelay: Double = 0
    @Published private(set) var usesVLC = false
    let native = AVPlayer()
    private var timer: Timer?
    private var status: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    #if canImport(MobileVLCKit)
    let vlc = VLCMediaPlayer()
    #endif

    func open(_ resource: PlaybackResource, resume: Double, subtitle: URL?, preferVLC: Bool, speed: Double) throws {
        stop(); error = nil; finished = false; position = 0; duration = 0; buffering = true
        audioTracks = []; subtitleTracks = []; audioID = -1; subtitleID = -1
        rate = Float(speed)
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try AVAudioSession.sharedInstance().setActive(true)
        #if canImport(MobileVLCKit)
        usesVLC = preferVLC || resource.url.scheme == "smb" || resource.username?.isEmpty == false
        if usesVLC {
            let media = VLCMedia(url: resource.url)
            media.addOption(":network-caching=1500")
            if resume > 0 { media.addOption(":start-time=\(resume)") }
            if let username = resource.username, !username.isEmpty {
                let prefix = resource.url.scheme == "smb" ? "smb" : "http"
                media.addOption(":\(prefix)-user=\(username)")
                media.addOption(":\(prefix)-pwd=\(resource.password ?? "")")
            }
            if let subtitle { media.addOption(":sub-file=\(subtitle.path)") }
            vlc.media = media; vlc.play(); vlc.rate = rate
        } else { openNative(resource.url, resume: resume) }
        #else
        usesVLC = false
        guard resource.username?.isEmpty != false, resource.url.scheme != "smb" else {
            throw AppError.message("认证共享播放需要 VLC。请在 Mac 执行 pod install 并打开 xcworkspace。")
        }
        if subtitle != nil { throw AppError.message("外部字幕需要 VLC。请切换到完整 VLC 构建。") }
        openNative(resource.url, resume: resume)
        #endif
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func openNative(_ url: URL, resume: Double) {
        let item = AVPlayerItem(url: url)
        native.replaceCurrentItem(with: item)
        status = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            if item.status == .failed {
                Task { @MainActor in self?.error = "系统播放器无法打开此视频。请使用 VLC 播放器或检查视频编码。" }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.finished = true }
        }
        if resume > 0 { native.seek(to: CMTime(seconds: resume, preferredTimescale: 600)) }
        native.playImmediately(atRate: rate)
    }

    private func tick() {
        #if canImport(MobileVLCKit)
        if usesVLC {
            position = max(0, Double(vlc.time.intValue) / 1000)
            duration = max(0, Double(vlc.media?.length.intValue ?? 0) / 1000)
            playing = vlc.isPlaying
            buffering = vlc.state == .opening || vlc.state == .buffering
            if vlc.state == .error { error = "视频打开失败，请检查共享权限、网络和文件格式。" }
            if vlc.state == .ended { finished = true }
            audioTracks = tracks(names: vlc.audioTrackNames, ids: vlc.audioTrackIndexes)
            subtitleTracks = tracks(names: vlc.videoSubTitlesNames, ids: vlc.videoSubTitlesIndexes)
            audioID = vlc.currentAudioTrackIndex; subtitleID = vlc.currentVideoSubTitleIndex
            return
        }
        #endif
        let current = native.currentTime().seconds
        let length = native.currentItem?.duration.seconds ?? 0
        position = current.isFinite ? max(0, current) : 0
        duration = length.isFinite ? max(0, length) : 0
        playing = native.rate > 0
        buffering = native.timeControlStatus == .waitingToPlayAtSpecifiedRate
    }

    #if canImport(MobileVLCKit)
    private func tracks(names: [Any]?, ids: [Any]?) -> [PlaybackTrack] {
        zip(names ?? [], ids ?? []).compactMap { name, id in
            guard let name = name as? String, let id = id as? NSNumber else { return nil }
            return PlaybackTrack(id: id.int32Value, name: name)
        }
    }
    #endif

    func toggle() {
        #if canImport(MobileVLCKit)
        if usesVLC { if vlc.isPlaying { vlc.pause() } else { vlc.play() }; return }
        #endif
        if native.rate > 0 { native.pause() } else { native.playImmediately(atRate: rate) }
    }

    func seek(_ value: Double) {
        let seconds = max(0, duration > 0 ? min(value, duration) : value)
        #if canImport(MobileVLCKit)
        if usesVLC { vlc.time = VLCTime(int: Int32(min(seconds * 1000, Double(Int32.max)))); return }
        #endif
        native.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    func setRate(_ speed: Float) {
        rate = speed
        #if canImport(MobileVLCKit)
        if usesVLC { vlc.rate = speed; return }
        #endif
        if playing { native.rate = speed }
    }

    func selectAudio(_ id: Int32) {
        #if canImport(MobileVLCKit)
        vlc.currentAudioTrackIndex = id
        #endif
    }

    func selectSubtitle(_ id: Int32) {
        #if canImport(MobileVLCKit)
        vlc.currentVideoSubTitleIndex = id
        #endif
    }

    func setSubtitleDelay(_ seconds: Double) {
        subtitleDelay = seconds
        #if canImport(MobileVLCKit)
        vlc.currentVideoSubTitleDelay = Int(seconds * 1_000_000)
        #endif
    }

    func chapter(next: Bool) {
        #if canImport(MobileVLCKit)
        if next { vlc.nextChapter() } else { vlc.previousChapter() }
        #endif
    }

    func stop() {
        timer?.invalidate(); timer = nil
        status = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }; endObserver = nil
        native.pause(); native.replaceCurrentItem(with: nil)
        #if canImport(MobileVLCKit)
        vlc.stop()
        #endif
        playing = false
    }
}
