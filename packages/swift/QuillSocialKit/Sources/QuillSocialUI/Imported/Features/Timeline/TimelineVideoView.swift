#if os(iOS)
import AVKit
import Feeds
import SwiftData
import SwiftUI

struct TimelineVideoView: View {
    let video: TimelineVideo
    @Query private var settings: [AppSettings]
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.videoPlaybackBounds) private var viewport
    @State private var playback = TimelineVideoPlaybackModel()
    @State private var frame: CGRect = .zero
    @State private var isVisible = false
    @State private var startedManually = false
    private let coordinator = VideoPlaybackCoordinator.shared

    private var policy: VideoPlaybackPolicy { settings.first?.videoPlaybackPolicy ?? .tapToPlay }

    var body: some View {
        FeedMediaViewport(aspectRatio: CGFloat(video.aspectRatio)) {
            ZStack {
                if let player = playback.player {
                    VideoPlayer(player: player)
                } else {
                    AsyncImage(url: video.thumbnailURL) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        Rectangle().fill(.black)
                    }
                    Button("Play Video", systemImage: "play.circle.fill") {
                        startedManually = true
                        coordinator.playManually(playback.id)
                        updatePlayback()
                    }
                    .labelStyle(.iconOnly)
                    .font(.system(size: 48))
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
                    .sensoryFeedback(.selection, trigger: startedManually)
                }
            }
            .accessibilityLabel(video.altText.isEmpty ? "Video" : video.altText)
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { newFrame in
            frame = newFrame
            updateVisibility()
        }
        .onScrollVisibilityChange(threshold: 0.01) { visible in
            isVisible = visible
            updateVisibility()
        }
        .onChange(of: viewport) { _, _ in updateVisibility() }
        .onChange(of: policy) { _, _ in updateVisibility() }
        .onChange(of: coordinator.activeID) { _, _ in updatePlayback() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                coordinator.suspend()
                playback.pause()
            } else {
                updateVisibility()
            }
        }
        .onDisappear {
            coordinator.remove(playback.id)
            playback.release()
            startedManually = false
        }
    }

    private func updateVisibility() {
        let visibleFraction: Double
        if !isVisible || scenePhase != .active {
            visibleFraction = 0
        } else if viewport.isEmpty || frame.isEmpty {
            visibleFraction = 1
        } else {
            let intersection = viewport.intersection(frame)
            visibleFraction = intersection.isNull ? 0 : Double(intersection.width * intersection.height / (frame.width * frame.height))
        }
        coordinator.update(playback.id, visibleFraction: visibleFraction, policy: policy)
        if visibleFraction <= 0 { playback.release() }
        updatePlayback()
    }

    private func updatePlayback() {
        guard coordinator.activeID == playback.id, scenePhase == .active else {
            playback.pause()
            return
        }
        playback.activate(video: video, manually: coordinator.isManualSelection(playback.id))
    }
}

#endif
