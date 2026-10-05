import SwiftUI

struct PodcastPlayerView: View {
    @Environment(PodcastLibraryModel.self) private var library
    @State private var expanded = false

    var body: some View {
        let player = library.player
        if let episode = player.episode {
            VStack(spacing: 8) {
                Button { expanded = true } label: {
                    HStack {
                        Image(systemName: "waveform")
                        Text(episode.title).font(.subheadline).lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.up")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Slider(value: Binding(get: { player.position }, set: { player.seek($0) }), in: 0...max(1, player.duration))
                    .accessibilityLabel("Playback Position")
                    .accessibilityValue(Self.time(player.position))
                HStack {
                    Text(Self.time(player.position)).monospacedDigit().font(.caption)
                    Spacer()
                    Button("Back 15 Seconds", systemImage: "gobackward.15") { player.skip(-15) }.labelStyle(.iconOnly)
                    Button(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill") {
                        player.isPlaying ? player.pause() : player.play()
                    }.labelStyle(.iconOnly)
                    Button("Forward 30 Seconds", systemImage: "goforward.30") { player.skip(30) }.labelStyle(.iconOnly)
                    Spacer()
                    Menu {
                        ForEach(Array(stride(from: 0.5, through: 3.0, by: 0.25)), id: \.self) { speed in
                            Button("\(speed.formatted())×") { Task { await library.setSpeed(speed) } }
                        }
                    } label: { Text("\(player.speed.formatted())×").monospacedDigit() }
                    .accessibilityLabel("Playback Speed")
                }
                if let error = player.error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            .padding()
            .background(.bar)
            .sheet(isPresented: $expanded) {
                NavigationStack {
                    PodcastNowPlayingView()
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { expanded = false } } }
                }
            }
        }
    }

    static func time(_ seconds: Double) -> String {
        let value = Int(max(0, seconds.isFinite ? seconds : 0))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
