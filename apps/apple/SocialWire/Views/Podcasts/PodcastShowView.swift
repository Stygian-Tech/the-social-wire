import SwiftUI

struct PodcastShowView: View {
    @Environment(PodcastLibraryModel.self) private var library
    let show: PodcastShow

    var body: some View {
        List {
            Section {
                if show.isPrivate { Label("Private RSS Feed", systemImage: "lock.fill") }
                if let description = show.description { Text(description).font(.subheadline) }
                Button(library.state.subscriptions.contains(show.id) ? "Unsubscribe" : "Subscribe") { Task { await library.toggleSubscription(show) } }
                    .disabled(show.isPrivate && !library.state.subscriptions.contains(show.id))
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
