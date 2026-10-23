import AVKit
import SwiftUI

struct PrototypeVideoView: View {
    let item: SampleMedia
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                VideoPlayer(player: player).frame(minHeight: 340)
                VStack(spacing: 8) {
                    Text(item.name).font(.headline)
                    Text(item.caption).font(.subheadline)
                    Text("\(item.videoSource) · Sample Clip").font(.caption).foregroundStyle(.secondary)
                    Text("CC0 flower footage demonstrates native playback.").font(.caption).foregroundStyle(.secondary)
                }.padding()
                Spacer()
            }
            .navigationTitle("Short Video").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear {
                if let url = Bundle.main.url(forResource: "flower", withExtension: "mp4") {
                    let playback = AVPlayer(url: url)
                    playback.isMuted = true
                    player = playback
                    playback.play()
                }
            }
            .onDisappear { player?.pause(); player = nil }
        }
    }
}
