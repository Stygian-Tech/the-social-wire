import SwiftUI

struct PodcastEpisodeListView: View {
    @Environment(PodcastLibraryModel.self) private var library
    let destination: PodcastLibraryDestination
    @State private var query = ""

    private var episodes: [PodcastEpisode] {
        let source: [PodcastEpisode]
        switch destination {
        case .recentlyAdded: source = library.recentEpisodes
        case .downloaded: source = library.downloadedEpisodes
        case .upNext: source = library.queuedEpisodes
        }
        return source.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            if destination == .downloaded {
                Section {
                    Text("\(library.downloads.downloadedIDs.count) Episodes • \(ByteCountFormatter.string(fromByteCount: library.downloads.storageBytes, countStyle: .file))")
                        .foregroundStyle(.secondary)
                } footer: { Text("Downloaded audio is stored on this device for offline playback. Use Save to Files or Share Audio to export a copy.") }
            }
            ForEach(episodes) { episode in PodcastEpisodeRow(episode: episode, inQueue: destination == .upNext) }
        }
        .overlay {
            if episodes.isEmpty {
                ContentUnavailableView(destination == .downloaded ? "No Downloads" : "No Episodes", systemImage: destination.systemImage,
                    description: Text(destination == .downloaded ? "Download an episode to listen offline or save it to Files." : "Episodes appear here as you subscribe and add to your queue."))
            }
        }
        .navigationTitle(destination.title)
        .searchable(text: $query, prompt: "Search Episodes")
        .refreshable {
            if destination == .recentlyAdded { await library.loadRecentEpisodes() }
            else if destination == .upNext { await library.sync(); await library.loadQueueEpisodes() }
        }
        .task {
            if destination == .recentlyAdded { await library.loadRecentEpisodes() }
            if destination == .upNext { await library.loadQueueEpisodes() }
        }
    }
}
