import SwiftUI

struct PodcastDirectoryPreviewView: View {
    @Environment(PodcastLibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss
    let candidate: PodcastDirectoryCandidate
    @State private var preview: PodcastResolvedSource?
    @State private var loadedViewer: String?
    @State private var loading = false
    @State private var subscribing = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                HStack {
                    PodcastArtworkView(url: candidate.artworkUrl, size: 72)
                    VStack(alignment: .leading) {
                        Text(candidate.title).font(.headline)
                        if let author = candidate.author { Text(author).foregroundStyle(.secondary) }
                    }
                }
                if let description = candidate.description { Text(description).font(.subheadline) }
                Link("Podcast Index", destination: URL(string: "https://podcastindex.org")!)
            }
            if loading { ProgressView("Loading Podcast") }
            if loadedViewer == library.viewer, let preview {
                Section {
                    if library.state.subscriptions.contains(preview.show.id) {
                        Label("Subscribed", systemImage: "checkmark")
                    } else {
                        Button("Subscribe") {
                            Task {
                                subscribing = true
                                defer { subscribing = false }
                                await library.toggleSubscription(preview.show)
                                if library.state.subscriptions.contains(preview.show.id) { dismiss() }
                                else { error = "Could Not Subscribe. Try Again." }
                            }
                        }.disabled(subscribing)
                    }
                }
                Section("Episodes") {
                    ForEach(preview.episodes) { episode in PodcastEpisodeRow(episode: episode) }
                    if preview.episodes.isEmpty { Text("No Episodes Available").foregroundStyle(.secondary) }
                }
            }
            if let error {
                Text(error).foregroundStyle(.red)
                Button("Retry") { Task { await load() } }
            }
        }
        .navigationTitle(candidate.title)
        .task(id: library.viewer) { await load() }
    }

    private func load() async {
        let viewer = library.viewer
        preview = nil
        loadedViewer = nil
        error = nil
        loading = true
        defer { if library.viewer == viewer { loading = false } }
        do {
            let result = try await library.previewPublicFeed(candidate.feedUrl)
            guard !Task.isCancelled, library.viewer == viewer else { return }
            preview = result
            loadedViewer = viewer
        } catch is CancellationError { } catch {
            guard !Task.isCancelled, library.viewer == viewer else { return }
            self.error = "Could Not Load This Podcast. Try Again."
        }
    }
}
