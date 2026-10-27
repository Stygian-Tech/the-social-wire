import AVKit
#if os(iOS)
import QuillSocialUI
#endif
import SwiftUI

struct SocialVideoPlayerView: View {
    let url: URL
    @State private var player: AVPlayer?
    @State private var failedToPrepareAudio = false

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
            } else if failedToPrepareAudio {
                ContentUnavailableView("Video Unavailable", systemImage: "play.slash")
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            player?.pause()
            player = nil
            failedToPrepareAudio = false
            #if os(iOS)
            do {
                try SocialVideoAudioSession.prepareForPlayback()
                player = AVPlayer(url: url)
            } catch {
                failedToPrepareAudio = true
            }
            #else
            player = AVPlayer(url: url)
            #endif
        }
        .onDisappear { player?.pause() }
    }
}
