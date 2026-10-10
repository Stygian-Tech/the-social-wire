import SwiftUI

struct PodcastsView: View {
    @Environment(PodcastLibraryModel.self) private var library
    @State private var addingPodcast = false
    @State private var importingOPML = false
    @State private var input = PodcastSearchInput()
    @State private var search = PodcastSearchModel()

    var body: some View {
        let identity = PodcastSearchIdentity(viewer: library.viewer, query: input.query, scope: input.scope)
        List {
            if !identity.normalizedQuery.isEmpty {
                PodcastSearchResultsView(identity: identity, search: search)
            } else if input.scope == .discover {
                ContentUnavailableView("Search Podcasts", systemImage: "magnifyingglass", description: Text("Search Podcast Index by title or keyword. Select a show to preview it before subscribing. Use Add Podcast for feed URLs."))
            } else {
                Section("Library") {
                    ForEach(PodcastLibraryDestination.allCases) { destination in
                        NavigationLink {
                            PodcastEpisodeListView(destination: destination)
                        } label: {
                            Label(destination.title, systemImage: destination.systemImage)
                        }
                    }
                    NavigationLink { PodcastClipsView() } label: { Label("Clips", systemImage: "scissors") }
                }
                Section("Subscribed Shows") {
                    if library.loading { ProgressView("Loading Podcasts") }
                    ForEach(library.shows.filter { library.state.subscriptions.contains($0.id) }) { show in
                        NavigationLink { PodcastShowView(show: show) } label: {
                            HStack {
                                PodcastArtworkView(url: show.artworkUrl, size: 40)
                                Text(show.title)
                                Spacer()
                                if show.isPrivate { Text("Private").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    if !library.shows.contains(where: { library.state.subscriptions.contains($0.id) }), !library.loading {
                        ContentUnavailableView("No Podcasts Yet", systemImage: "headphones", description: Text("Add a public feed, a private RSS feed, or an on-protocol podcast."))
                    }
                }
            }
            if input.scope == .library, identity.normalizedQuery.isEmpty, let error = library.error {
                Section {
                    Text(error).foregroundStyle(.red)
                    Button("Retry") { Task { await library.refresh() } }
                }
            }
        }
        .searchable(text: $input.query, prompt: input.scope == .library ? "Search Your Podcast Library" : "Search Podcast Index")
        .searchScopes(Binding(get: { input.scope }, set: { input = input.selecting($0) })) {
            ForEach(PodcastSearchScope.allCases, id: \.self) { scope in Text(scope.title).tag(scope) }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Add Podcast", systemImage: "plus") { addingPodcast = true }
                    Button("Import OPML", systemImage: "square.and.arrow.down") { importingOPML = true }
                } label: { Label("Add Podcast", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $importingOPML) { OPMLImportView(initialDestination: .podcasts) }
        .sheet(isPresented: $addingPodcast) { NavigationStack { PodcastDiscoveryView() } }
        .refreshable { await library.refresh() }
        .task { await library.refresh() }
        .task(id: identity) { await search.search(identity, fetch: library.searchPage) }
    }
}
