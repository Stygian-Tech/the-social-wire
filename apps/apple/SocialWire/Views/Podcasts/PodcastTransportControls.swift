import SwiftUI

struct PodcastTransportControls: View {
    @Environment(PodcastLibraryModel.self) private var library
    var body: some View {
        HStack {
            Text(PodcastPlayerView.time(library.player.position)).monospacedDigit().font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 24) {
                Button("Back 15 Seconds", systemImage: "gobackward.15") { library.player.skip(-15) }.labelStyle(.iconOnly)
                Button(library.player.isPlaying ? "Pause" : "Play", systemImage: library.player.isPlaying ? "pause.fill" : "play.fill") {
                    library.player.isPlaying ? library.player.pause() : library.player.play()
                }.labelStyle(.iconOnly)
                Button("Forward 30 Seconds", systemImage: "goforward.30") { library.player.skip(30) }.labelStyle(.iconOnly)
            }
            Menu {
                ForEach(Array(stride(from: 0.75, through: 2.0, by: 0.25)), id: \.self) { speed in
                    Button("\(speed.formatted())×") { Task { await library.setSpeed(speed) } }
                }
            } label: { Text("\(library.player.speed.formatted())×").monospacedDigit() }
            .accessibilityLabel("Playback Speed")
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

}
