import SwiftUI

struct PodcastSearchResultsView: View {
    @Environment(PodcastLibraryModel.self) private var library
    let identity: PodcastSearchIdentity
    let search: PodcastSearchModel

    var body: some View {
        if !identity.isValid {
            Text(identity.scope == .library ? "Enter 2–200 Characters to Search Your Library." : "Enter 2–200 Characters to Search Podcast Index.").foregroundStyle(.secondary)
        } else if search.identity == identity {
            if !search.candidates.isEmpty {
                Section {
                    ForEach(search.candidates) { candidate in
                        NavigationLink { PodcastDirectoryPreviewView(candidate: candidate) } label: {
                            HStack {
                                PodcastArtworkView(url: candidate.artworkUrl, size: 40)
                                VStack(alignment: .leading) {
                                    Text(candidate.title)
                                    if let author = candidate.author { Text(author).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                } header: { Text("Search") } footer: {
                    Link("Results from Podcast Index", destination: URL(string: "https://podcastindex.org")!)
                }
            }
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
            if search.loading { ProgressView(identity.scope == .library ? "Searching Library" : "Searching Podcast Index") }
            if let error = search.error {
                Text(error).foregroundStyle(.red)
                Button("Retry Search") { Task { await search.search(identity, debounce: false, fetch: library.searchPage) } }
            } else if search.shows.isEmpty, search.episodes.isEmpty, search.candidates.isEmpty, !search.loading, !search.hasMore {
                ContentUnavailableView.search(text: identity.normalizedQuery)
            }
            if search.hasMore {
                Button("Load More Results") { Task { await search.loadMore(fetch: library.searchPage) } }
                    .disabled(search.loading)
            }
        } else { ProgressView(identity.scope == .library ? "Searching Library" : "Searching Podcast Index") }
    }
}
