import SwiftUI

struct PodcastDiscoveryView: View {
    @Environment(PodcastLibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var privateFeed = false

    var body: some View {
        Form {
            Section {
                TextField(privateFeed ? "Private RSS Feed URL" : "Feed URL, Handle, or AT URI", text: $input)
                    .autocorrectionDisabled()
                Toggle("Private RSS Feed", isOn: $privateFeed)
                Button(privateFeed ? "Subscribe Privately" : "Find Podcast", systemImage: privateFeed ? "lock" : "magnifyingglass") {
                    Task {
                        await library.resolve(input, privateFeed: privateFeed)
                        if privateFeed, library.error == nil { input = ""; dismiss() }
                    }
                }
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || library.loading)
            } footer: {
                Text(privateFeed
                     ? "Private feeds stay in your account and on this device. Their URLs are never published to your PDS or mirrored to AT Protocol."
                     : "Public RSS feeds are mirrored to AT Protocol with source attribution. Choose Private RSS Feed for subscriber-only or credential-bearing feeds.")
            }
            if library.loading { ProgressView(privateFeed ? "Subscribing Privately" : "Finding Podcast") }
            if let error = library.error { Text(error).foregroundStyle(.red) }
            if !privateFeed, library.resolvedShows.count > 1 {
                Section("Choose a Show") {
                    ForEach(library.resolvedShows) { candidate in
                        Button(candidate.title) {
                            if let input = candidate.sourceUri ?? candidate.feedUrl { Task { await library.resolve(input) } }
                        }
                    }
                }
            }
            if !privateFeed, let show = library.resolvedShow {
                Section("Podcast") {
                    Text(show.title).font(.headline)
                    if let description = show.description { Text(description).font(.subheadline) }
                    if library.state.subscriptions.contains(show.id) { Label("Subscribed", systemImage: "checkmark") }
                    else {
                        Button("Subscribe") {
                            Task {
                                await library.toggleSubscription(show)
                                if library.error == nil { dismiss() }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Add Podcast")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
}
