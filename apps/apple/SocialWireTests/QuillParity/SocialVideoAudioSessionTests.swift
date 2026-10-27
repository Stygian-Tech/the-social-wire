#if os(iOS)
import AVFoundation
import Feeds
import Foundation
import Testing
@testable import QuillSocialUI

@MainActor
struct SocialVideoAudioSessionTests {
    private enum PreparationFailure: Error, Equatable { case unavailable }

    @Test("Mixing is configured before activation without ducking or interrupting other audio")
    func mixesBeforeActivation() throws {
        var configured = false
        var activated = false
        try SocialVideoAudioSession.prepareForPlayback { category, mode, options in
            #expect(category == .playback)
            #expect(mode == .moviePlayback)
            #expect(options == [.mixWithOthers])
            #expect(!activated)
            configured = true
        } activate: {
            #expect(configured)
            activated = true
        }
        #expect(activated)
    }

    @Test("A failed mixing configuration never activates the audio session")
    func configurationFailureDoesNotActivate() {
        var activated = false
        #expect(throws: PreparationFailure.unavailable) {
            try SocialVideoAudioSession.prepareForPlayback { _, _, _ in
                throw PreparationFailure.unavailable
            } activate: {
                activated = true
            }
        }
        #expect(!activated)
    }

    @Test("Video preparation failures do not start a player and remain retryable")
    func videoPreparationFailureIsRetryable() {
        var attempts = 0
        let model = TimelineVideoPlaybackModel(coordinator: VideoPlaybackCoordinator()) {
            attempts += 1
            throw PreparationFailure.unavailable
        }
        let video = TimelineVideo(playlistURL: URL(fileURLWithPath: "/unused-video.mp4"))
        model.activate(video: video, manually: false)
        #expect(model.player == nil)
        model.activate(video: video, manually: true)
        #expect(attempts == 2)
        #expect(model.player == nil)
    }
}
#endif
