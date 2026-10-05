import SwiftUI

struct PodcastsView: View {
    @Environment(PodcastLibraryModel.self) private var library
    @State private var addingPodcast = false
    @State private var query = ""

    var body: some View {
        List {
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
                ForEach(library.shows.filter { library.state.subscriptions.contains($0.id) && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) }) { show in
                    NavigationLink { PodcastShowView(show: show) } label: {
                        HStack {
                            Image(systemName: show.isPrivate ? "lock.fill" : "mic")
                                .foregroundStyle(.secondary)
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
            if let error = library.error {
                Section {
                    Text(error).foregroundStyle(.red)
                    Button("Retry") { Task { await library.refresh() } }
                }
            }
        }
        .searchable(text: $query, prompt: "Search Shows")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add Podcast", systemImage: "plus") { addingPodcast = true }
            }
        }
        .sheet(isPresented: $addingPodcast) { NavigationStack { PodcastDiscoveryView() } }
        .refreshable { await library.refresh() }
        .task { await library.refresh() }
    }
}
