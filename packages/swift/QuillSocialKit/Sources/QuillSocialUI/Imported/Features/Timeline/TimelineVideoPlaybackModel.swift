#if os(iOS)
import AVFoundation
import Feeds
import Observation

@MainActor
@Observable
final class TimelineVideoPlaybackModel {
    let id = UUID()
    private(set) var player: AVPlayer?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private let coordinator: VideoPlaybackCoordinator
    @ObservationIgnored private let prepareAudio: @MainActor () throws -> Void

    init(
        coordinator: VideoPlaybackCoordinator = .shared,
        prepareAudio: @escaping @MainActor () throws -> Void = SocialVideoAudioSession.prepareForPlayback
    ) {
        self.coordinator = coordinator
        self.prepareAudio = prepareAudio
    }

    func activate(video: TimelineVideo, manually: Bool) {
        guard !isActive else { return }
        // Configure mixing before AVPlayer can activate an exclusive audio session.
        // If preparation fails, leave the existing audio and video playback alone.
        do { try prepareAudio() } catch { return }
        isActive = true
        if player == nil {
            let newPlayer = AVPlayer(url: video.playlistURL)
            player = newPlayer
            observation = newPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                let status = player.timeControlStatus.rawValue
                Task { @MainActor [weak self] in
                    self?.nativePlaybackChanged(status: status)
                }
            }
        }
        // Automatic activations are always silent, including a formerly manual
        // player that returns after another clip becomes the winner.
        if !manually { player?.isMuted = true }
        player?.play()
    }

    func pause() {
        isActive = false
        player?.pause()
    }

    func release() {
        pause()
        observation?.invalidate()
        observation = nil
        player = nil
    }

    private func nativePlaybackChanged(status: Int) {
        // KVO delivery crosses onto the main actor; ignore queued transitions
        // superseded by a later pause, release, or activation.
        guard let player, player.timeControlStatus.rawValue == status else { return }
        if status == AVPlayer.TimeControlStatus.playing.rawValue {
            if coordinator.activeID != id {
                coordinator.playManually(id)
                isActive = true
            }
        } else if status == AVPlayer.TimeControlStatus.paused.rawValue, isActive {
            isActive = false
            coordinator.pauseByUser(id)
        }
    }
}

#endif
