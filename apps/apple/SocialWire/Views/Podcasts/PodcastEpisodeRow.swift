import SwiftUI
import UniformTypeIdentifiers

struct PodcastEpisodeRow: View {
    @Environment(PodcastLibraryModel.self) private var library
    let episode: PodcastEpisode
    var inQueue = false
    @State private var confirmsDelete = false
    @State private var exporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { Task { await library.play(episode) } } label: {
                HStack(alignment: .top) {
                    Image(systemName: episode.isPrivate ? "lock.fill" : "play.circle.fill")
                        .font(.title2).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(episode.title).font(.headline).foregroundStyle(.primary)
                        HStack {
                            if let duration = episode.durationSeconds { Text(PodcastPlayerView.time(duration)) }
                            if episode.isPrivate { Text("Private") }
                            if library.state.progress[episode.id]?.completed == true { Text("Played") }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if library.preparingEpisodeID == episode.id {
                Text("Preparing Audio for Playback").font(.caption).foregroundStyle(.secondary)
            }
            if let progress = library.downloads.progress[episode.id] {
                HStack {
                    ProgressView(value: progress)
                    Button("Cancel") { library.cancelDownload(episode.id) }
                }
                .accessibilityLabel("Downloading Episode")
                .accessibilityValue("\(Int(progress * 100)) Percent")
            }
            HStack {
                Button(inQueue ? "Remove from Up Next" : "Add to Up Next", systemImage: inQueue ? "minus.circle" : "text.badge.plus") {
                    Task { if inQueue { await library.removeFromQueue(episode.id) } else { await library.enqueue(episode) } }
                }
                .font(.caption)
                Spacer()
                Menu {
                    if let file = library.downloads.localURL(episode.id) {
                        Button("Save to Files", systemImage: "folder") { exporting = true }
                        ShareLink(item: PodcastAudioFile(url: file), preview: SharePreview(episode.title)) {
                            Label("Share Audio", systemImage: "square.and.arrow.up")
                        }
                        Button("Delete Download", systemImage: "trash", role: .destructive) { confirmsDelete = true }
                    } else if library.downloads.progress[episode.id] == nil {
                        Button(library.downloads.errors[episode.id] == nil ? "Download to Device" : "Retry Download", systemImage: "arrow.down.circle") {
                            Task { await library.download(episode) }
                        }
                    }
                } label: { Image(systemName: "ellipsis.circle").font(.title3) }
                .accessibilityLabel("Episode Actions")
            }
            if let error = library.downloads.errors[episode.id] { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding(.vertical, 4)
        .fileExporter(isPresented: $exporting,
            item: library.downloads.localURL(episode.id).map(PodcastAudioFile.init),
            contentTypes: [.audio], defaultFilename: library.downloads.exportFilename(for: episode)) { result in
                if case .failure = result { library.error = "Could Not Save Audio. Check Available Storage and Try Again." }
            }
        .confirmationDialog("Delete Download?", isPresented: $confirmsDelete) {
            Button("Delete Download", role: .destructive) { library.downloads.delete(episode.id) }
            Button("Cancel", role: .cancel) { }
        }
    }
}
