import SwiftUI

struct PodcastSearchResultsView: View {
    @Environment(PodcastLibraryModel.self) private var library
    let identity: PodcastSearchIdentity
    let search: PodcastSearchModel

    var body: some View {
        if !identity.isValid {
            Text("Enter 2–200 Characters to Search Your Library.").foregroundStyle(.secondary)
        } else if search.identity == identity {
            if !search.shows.isEmpty {
                Section("Shows") {
                    ForEach(search.shows) { show in
                        NavigationLink { PodcastShowView(show: show) } label: {
                            HStack {
                                PodcastArtworkView(url: show.artworkUrl, size: 40)
                                Text(show.title)
                                if show.isPrivate { Image(systemName: "lock.fill").accessibilityLabel("Private") }
                            }
                        }
                    }
                }
            }
            if !search.episodes.isEmpty {
                Section("Episodes") {
                    ForEach(search.episodes) { episode in
                        PodcastEpisodeRow(episode: episode, inQueue: library.state.queue.contains(episode.id))
                    }
                }
            }
            if search.loading { ProgressView("Searching Library") }
            if let error = search.error {
                Text(error).foregroundStyle(.red)
                Button("Retry Search") { Task { await search.search(identity, debounce: false, fetch: library.searchPage) } }
            } else if search.shows.isEmpty, search.episodes.isEmpty, !search.loading, !search.hasMore {
                ContentUnavailableView.search(text: identity.normalizedQuery)
            }
            if search.hasMore {
                Button("Load More Results") { Task { await search.loadMore(fetch: library.searchPage) } }
                    .disabled(search.loading)
            }
        } else { ProgressView("Searching Library") }
    }
}
