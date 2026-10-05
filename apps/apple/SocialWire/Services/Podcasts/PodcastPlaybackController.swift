import AVFoundation
import Foundation
import MediaPlayer
import Observation

/// Owns one player for the entire app, independently of the selected navigation tab.
@MainActor
@Observable
final class PodcastPlaybackController {
    private(set) var episode: PodcastEpisode?
    private(set) var showTitle: String?
    private(set) var position = 0.0
    private(set) var duration = 0.0
    private(set) var isPlaying = false
    private(set) var error: String?
    var speed = 1.0 {
        didSet {
            let normalized = Self.normalizedSpeed(speed)
            if normalized != speed { speed = normalized; return }
            if isPlaying { player.rate = Float(speed) }
            updateNowPlaying()
        }
    }
    var removesSilence = false
    var silenceIntervals: [PodcastSilenceInterval] = []
    var onProgress: ((String, Double, Bool) -> Void)?
    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var notifications: [NSObjectProtocol] = []
    @ObservationIgnored private var remoteTargets: [(MPRemoteCommand, Any)] = []
    @ObservationIgnored private var shouldResumeAfterInterruption = false
    @ObservationIgnored private var previewEnd: Double?
    @ObservationIgnored private var lastReportedPosition = -10.0

    init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in self?.tick(time.seconds) }
        }
        let center = NotificationCenter.default
        notifications.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            guard let item = note.object as? AVPlayerItem else { return }
            let identity = ObjectIdentifier(item)
            Task { @MainActor [weak self] in
                guard let self, let current = self.player.currentItem, ObjectIdentifier(current) == identity else { return }
                self.isPlaying = false
                if let id = self.episode?.id { self.onProgress?(id, self.duration, true) }
                self.updateNowPlaying()
            }
        })
#if os(iOS)
        notifications.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor [weak self] in self?.interruption(type: type, options: options) }
        })
        notifications.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor [weak self] in
                if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { self?.pause() }
            }
        })
#endif
        let remote = MPRemoteCommandCenter.shared()
        register(remote.playCommand) { $0.play() }
        register(remote.pauseCommand) { $0.pause() }
        register(remote.togglePlayPauseCommand) { $0.isPlaying ? $0.pause() : $0.play() }
        remote.skipBackwardCommand.preferredIntervals = [15]
        remote.skipForwardCommand.preferredIntervals = [30]
        register(remote.skipBackwardCommand) { $0.skip(-15) }
        register(remote.skipForwardCommand) { $0.skip(30) }
        remote.changePlaybackPositionCommand.isEnabled = true
        let target = remote.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let seconds = event.positionTime
            Task { @MainActor [weak self] in self?.seek(seconds) }
            return .success
        }
        remoteTargets.append((remote.changePlaybackPositionCommand, target))
    }

    isolated deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        for observer in notifications { NotificationCenter.default.removeObserver(observer) }
        for (command, target) in remoteTargets { command.removeTarget(target) }
    }

    nonisolated static func normalizedSpeed(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(3, max(0.5, (value * 4).rounded() / 4))
    }

    func load(_ episode: PodcastEpisode, localURL: URL? = nil, resume: Double = 0, showTitle: String? = nil) {
        guard let url = localURL ?? URL(string: episode.audioURL) else { error = "Audio Is Unavailable"; return }
        pause()
        self.episode = episode
        self.showTitle = showTitle
        position = max(0, resume)
        duration = episode.durationSeconds ?? 0
        silenceIntervals = []
        previewEnd = nil
        lastReportedPosition = -10
        error = nil
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .timeDomain
        player.replaceCurrentItem(with: item)
        seek(resume)
        play()
    }

    func play() {
        guard episode != nil else { return }
        if duration > 0, position >= duration { seek(0) }
#if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { self.error = error.localizedDescription; return }
#endif
        player.playImmediately(atRate: Float(speed))
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        player.pause()
        isPlaying = false
        if let id = episode?.id { onProgress?(id, position, false) }
        updateNowPlaying()
    }

    func seek(_ seconds: Double) {
        guard seconds.isFinite else { return }
        position = max(0, duration > 0 ? min(duration, seconds) : seconds)
        player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        updateNowPlaying()
    }

    func preview(start: Double, end: Double) {
        previewEnd = end
        seek(start)
        play()
    }

    func skip(_ seconds: Double) { seek(position + seconds) }

    func reset() {
        pause()
        player.replaceCurrentItem(with: nil)
        episode = nil
        showTitle = nil
        position = 0
        duration = 0
        silenceIntervals = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite, episode != nil else { return }
        position = max(0, seconds)
        if let previewEnd, position >= previewEnd { self.previewEnd = nil; pause() }
        if let item = player.currentItem {
            if item.duration.seconds.isFinite { duration = item.duration.seconds }
            if let failure = item.error { error = failure.localizedDescription; isPlaying = false }
        }
        if removesSilence, isPlaying, let destination = silenceIntervals.compactMap({ $0.destination(at: position) }).first {
            seek(destination)
        }
        if abs(position - lastReportedPosition) >= 10, let id = episode?.id {
            lastReportedPosition = position
            onProgress?(id, position, false)
        }
        updateNowPlaying()
    }

    private func register(_ command: MPRemoteCommand, action: @escaping @MainActor (PodcastPlaybackController) -> Void) {
        command.isEnabled = true
        let target = command.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in if let self { action(self) } }
            return .success
        }
        remoteTargets.append((command, target))
    }

    private func updateNowPlaying() {
        guard let episode else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: episode.title,
            MPMediaItemPropertyArtist: showTitle ?? "Podcast",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? speed : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: speed,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
    }

#if os(iOS)
    private func interruption(type: UInt?, options: UInt) {
        if type == AVAudioSession.InterruptionType.began.rawValue {
            shouldResumeAfterInterruption = isPlaying
            pause()
        } else if type == AVAudioSession.InterruptionType.ended.rawValue {
            if shouldResumeAfterInterruption, AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) { play() }
            shouldResumeAfterInterruption = false
        }
    }
#endif
}
