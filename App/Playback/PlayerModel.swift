import Foundation
import AVKit
import Combine
import MediaPlayer
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
    var title = ""
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private var interruptionObserver: NSObjectProtocol?
    @Published var audioDelay: Double = 0
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
        usesVLC = preferVLC || resource.url.scheme == "smb" || resource.username?.isEmpty == false || subtitle != nil
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
            let settings = UserDefaults.standard
            media.addOption(":freetype-font=\(settings.string(forKey: "subtitleFont") ?? "Helvetica Neue")")
            media.addOption(":freetype-rel-fontsize=\(settings.integer(forKey: "subtitleSize") == 0 ? 5 : settings.integer(forKey: "subtitleSize"))")
            media.addOption(":freetype-opacity=\(settings.object(forKey: "subtitleOpacity") as? Int ?? 255)")
            media.addOption(":freetype-background-opacity=\(settings.integer(forKey: "subtitleBackground"))")
            media.addOption(":freetype-outline-thickness=\(settings.object(forKey: "subtitleOutline") as? Int ?? 2)")
            media.addOption(":freetype-color=\(settings.object(forKey: "subtitleColor") as? Int ?? 16777215)")
            vlc.media = media; vlc.play(); vlc.rate = rate
        } else { openNative(resource.url, resume: resume) }
        #else
        usesVLC = false
        guard resource.username?.isEmpty != false, resource.url.scheme != "smb" else {
            throw AppError.message("此版本暂不支持认证共享播放，请安装包含 VLC 的完整播放器版本。")
        }
        if subtitle != nil { throw AppError.message("外部字幕需要 VLC。请切换到完整 VLC 构建。") }
        openNative(resource.url, resume: resume)
        #endif
        installRemoteCommands()
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
        defer { updateNowPlaying() }
        #if canImport(MobileVLCKit)
        if usesVLC {
            position = max(0, Double(vlc.time.intValue) / 1000)
            duration = max(0, Double(vlc.media?.length.intValue ?? 0) / 1000)
            playing = vlc.isPlaying
            buffering = vlc.state == .opening || vlc.state == .buffering
            if vlc.state == .error { error = "视频打开失败，请检查共享权限、网络和文件格式。" }
            if vlc.state == .ended { position = duration; finished = true }
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

    func pause() {
        #if canImport(MobileVLCKit)
        if usesVLC { vlc.pause(); return }
        #endif
        native.pause()
    }

    func setAudioDelay(_ seconds: Double) {
        audioDelay = seconds
        #if canImport(MobileVLCKit)
        vlc.currentAudioPlaybackDelay = Int(seconds * 1_000_000)
        #endif
    }

    func setAspect(_ ratio: String) {
        #if canImport(MobileVLCKit)
        if ratio == "自动" { vlc.videoAspectRatio = nil }
        else { ratio.withCString { vlc.videoAspectRatio = UnsafeMutablePointer(mutating: $0) } }
        #endif
    }

    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        func command(_ command: MPRemoteCommand, _ action: @escaping @MainActor () -> Void) {
            let token = command.addTarget { _ in Task { @MainActor in action() }; return .success }
            remoteTargets.append((command, token))
        }
        command(center.playCommand) { [weak self] in if self?.playing == false { self?.toggle() } }
        command(center.pauseCommand) { [weak self] in self?.pause() }
        command(center.togglePlayPauseCommand) { [weak self] in self?.toggle() }
        center.skipForwardCommand.preferredIntervals = [15]; center.skipBackwardCommand.preferredIntervals = [15]
        command(center.skipForwardCommand) { [weak self] in if let self { self.seek(self.position + 15) } }
        command(center.skipBackwardCommand) { [weak self] in if let self { self.seek(self.position - 15) } }
        let token = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let value = event.positionTime; Task { @MainActor in self?.seek(value) }; return .success
        }
        remoteTargets.append((center.changePlaybackPositionCommand, token))
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            if notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue {
                Task { @MainActor in self?.pause() }
            }
        }
        updateNowPlaying()
    }

    private func updateNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyPlaybackDuration: duration, MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? rate : 0]
    }

    func stop() {
        for (command, token) in remoteTargets { command.removeTarget(token) }; remoteTargets = []
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }; interruptionObserver = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
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
