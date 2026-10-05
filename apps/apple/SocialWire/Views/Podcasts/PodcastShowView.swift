import SwiftUI

struct PodcastShowView: View {
    @Environment(PodcastLibraryModel.self) private var library
    let show: PodcastShow

    var body: some View {
        List {
            Section {
                PodcastArtworkView(url: show.artworkUrl, size: 96)
                if show.isPrivate { Label("Private RSS Feed", systemImage: "lock.fill") }
                if let description = show.description { Text(description).font(.subheadline) }
                Button(library.state.subscriptions.contains(show.id) ? "Unsubscribe" : "Subscribe") { Task { await library.toggleSubscription(show) } }
                    .disabled(show.isPrivate && !library.state.subscriptions.contains(show.id))
            }
            if let hosts = show.hosts, !hosts.isEmpty {
                Section("Hosts") {
                    ForEach(hosts, id: \.self) { host in
                        HStack {
                            PodcastArtworkView(url: host.imageUrl)
                            VStack(alignment: .leading) {
                                Text(host.name)
                                if let role = host.role { Text(role).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
            ForEach(library.showEpisodes[show.id] ?? []) { episode in PodcastEpisodeRow(episode: episode) }
            if library.loading { ProgressView("Loading Episodes") }
            if let error = library.error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle(show.title)
        .task { await library.loadEpisodes(show: show) }
        .refreshable {
            if show.isPrivate { await library.refreshPrivateShow(show) }
            else { await library.loadEpisodes(show: show) }
        }
    }
}
