import SwiftUI

struct PodcastPlayerView: View {
    @Environment(PodcastLibraryModel.self) private var library
    @State private var expanded = false
    @State private var minimized = false
    @State private var hovering = false
    @FocusState private var artworkFocused: Bool

    var body: some View {
        let player = library.player
        if let episode = player.episode {
            let chapter = episode.activeChapter(at: player.position)
            let art = chapter?.artworkUrl ?? episode.artworkUrl ?? episode.showArtworkUrl ?? library.currentShow?.artworkUrl
            VStack(spacing: 8) {
                if minimized {
                    HStack {
                        Button { minimized = false } label: { PodcastArtworkView(url: art) }
                            .buttonStyle(.plain).focusable().focused($artworkFocused)
                            .accessibilityLabel("Expand Player: \(episode.title)")
                            .help("Expand Player")
                        if hovering || artworkFocused {
                            VStack(alignment: .leading) {
                                Text(episode.title).lineLimit(1)
                                if let chapter { Text(chapter.title).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }
                            Spacer()
                            playButton
                        }
                    }
                    .onHover { hovering = $0 }
                } else {
                    HStack {
                        Button { expanded = true } label: {
                            HStack {
                                PodcastArtworkView(url: art)
                                VStack(alignment: .leading) {
                                    Text(episode.title).font(.subheadline).lineLimit(1)
                                    if let chapter { Text(chapter.title).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                }
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("Now Playing: \(episode.title)")
                        Spacer()
                        Button("Minimize Player", systemImage: "chevron.down") { minimized = true }.labelStyle(.iconOnly)
                    }
                    Slider(value: Binding(get: { player.position }, set: { player.seek($0) }), in: 0...max(1, player.duration))
                        .accessibilityLabel("Playback Position").accessibilityValue(Self.time(player.position))
                    PodcastTransportControls()
                    if let error = player.error { Text(error).font(.caption).foregroundStyle(.red) }
                }
            }
            .padding().background(.bar)
            .sheet(isPresented: $expanded) {
                NavigationStack {
                    PodcastNowPlayingView()
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { expanded = false } } }
                }
            }
        }
    }

    private var playButton: some View {
        Button(library.player.isPlaying ? "Pause" : "Play", systemImage: library.player.isPlaying ? "pause.fill" : "play.fill") {
            library.player.isPlaying ? library.player.pause() : library.player.play()
        }.labelStyle(.iconOnly)
    }

    static func time(_ seconds: Double) -> String {
        let value = Int(max(0, seconds.isFinite ? seconds : 0))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
