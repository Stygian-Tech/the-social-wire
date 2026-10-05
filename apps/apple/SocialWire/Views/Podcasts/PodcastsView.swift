import SwiftUI

struct PodcastsView: View {
    @Environment(PodcastLibraryModel.self) private var library
    @State private var feedURL = ""
    @State private var selectedShow: PodcastShow?
    @State private var deleteID: String?
    @State private var exportedMedia: [String: URL] = [:]
    @State private var exporting = false
    @State private var clipToUnpublish: PodcastClip?
    @State private var query = ""

    var body: some View {
        List {
            Section("Add Podcast") {
                TextField("RSS URL or AT URI", text: $feedURL)
                    .autocorrectionDisabled()
                Button("Find Podcast", systemImage: "magnifyingglass") { Task { await library.resolve(feedURL); selectedShow = library.resolvedShow } }
                    .disabled(feedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || library.loading)
                Text("Public RSS feeds are mirrored to AT Protocol with source attribution. Private feeds are not supported.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if library.loading { ProgressView("Loading Podcasts") }
            if let error = library.error {
                Text(error).foregroundStyle(.red)
                Button("Retry") { Task { await library.refresh() } }
            }
            Section("Podcasts") {
                ForEach(library.shows.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }) { show in
                    HStack {
                        Button { selectedShow = show; Task { await library.loadEpisodes(show: show) } } label: {
                            Label(show.title, systemImage: "mic")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        if show.sourceKind == "rss" {
                            Menu("Link Protocol Podcast") {
                                if library.state.manualLinks.contains(where: { $0["rssShowId"] == show.id }) {
                                    Button("Unlink Protocol Podcast") { Task { await library.unlinkShows(rss: show) } }
                                }
                                ForEach(library.shows.filter { $0.sourceKind == "atproto" }) { protocolShow in
                                    Button(protocolShow.title) { Task { await library.linkShows(rss: show, protocolShow: protocolShow) } }
                                }
                            }
                        }
                        Button(library.state.subscriptions.contains(show.id) ? "Unsubscribe" : "Subscribe") {
                            Task { await library.toggleSubscription(show) }
                        }
                    }
                }
            }
            if let selectedShow, let status = library.bridgeStatus[selectedShow.id] {
                Section("Protocol Publication") {
                    Text(status.capitalized)
                    if let error = library.bridgeErrors[selectedShow.id] { Text(error).foregroundStyle(.red) }
                    if status == "failed" { Button("Retry Publication") { Task { await library.retryBridge(showId: selectedShow.id) } } }
                    Button("Refresh Status") { Task { await library.refreshBridgeStatus(showId: selectedShow.id) } }
                }
            }
            Section(selectedShow?.title ?? "Episodes") {
                ForEach(library.episodes.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }) { episode in
                    VStack(alignment: .leading, spacing: 8) {
                        Button { Task { await library.play(episode) } } label: {
                            Label(episode.title, systemImage: "play.circle")
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }
                        HStack {
                            Button("Add to Queue", systemImage: "text.badge.plus") { Task { await library.enqueue(episode) } }
                            Spacer()
                            if library.downloads.downloadedIDs.contains(episode.id) {
                                Button("Delete Download", systemImage: "trash") { deleteID = episode.id }
                            } else if let progress = library.downloads.progress[episode.id] {
                                ProgressView(value: progress).frame(width: 60)
                                Button("Cancel Download") { library.downloads.cancel(episode.id) }
                            } else {
                                Button(library.downloads.errors[episode.id] == nil ? "Download" : "Retry Download", systemImage: "arrow.down.circle") {
                                    library.downloads.download(episode)
                                }
                            }
                        }
                        .font(.caption)
                        if let error = library.downloads.errors[episode.id] { Text(error).font(.caption).foregroundStyle(.red) }
                    }
                }
            }
            if !library.state.queue.isEmpty {
                Section("Queue") {
                    ForEach(library.state.queue, id: \.self) { id in
                        HStack {
                            Button(library.episodes.first(where: { $0.id == id })?.title ?? "Episode") {
                                Task { await library.playQueued(id) }
                            }
                            Spacer()
                            Button("Remove", systemImage: "minus.circle") { Task { await library.removeFromQueue(id) } }
                        }
                    }
                }
            }
            Section("Downloads") {
                Text("\(library.downloads.downloadedIDs.count) Episodes • \(ByteCountFormatter.string(fromByteCount: library.downloads.storageBytes, countStyle: .file))")
            }
            if !library.clips.isEmpty {
                Section("Clips") {
                    ForEach(library.clips) { clip in
                        VStack(alignment: .leading) {
                            Text(clip.title)
                            Text(clip.status.capitalized).font(.caption).foregroundStyle(.secondary)
                            if let url = library.clipURL(clip) {
                                ShareLink(item: url) { Label("Share Clip", systemImage: "square.and.arrow.up") }
                            }
                            if clip.audioUrl != nil, clip.videoUrl != nil {
                                HStack {
                                    ForEach([false, true], id: \.self) { video in
                                        let key = "\(clip.id)-\(video)"
                                        if let file = exportedMedia[key] {
                                            ShareLink(item: file) { Text(video ? "Share Audiogram" : "Share Audio") }
                                        } else {
                                            Button(video ? "Export Audiogram" : "Export Audio") {
                                                exporting = true
                                                Task {
                                                    exportedMedia[key] = await library.exportMedia(clip, video: video)
                                                    exporting = false
                                                }
                                            }.disabled(exporting)
                                        }
                                    }
                                }
                            }
                            Button(clip.publishedUri == nil ? "Publish" : "Unpublish") {
                                if clip.publishedUri != nil { clipToUnpublish = clip }
                                else { Task { await library.toggleClipPublication(clip) } }
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Search Podcasts")
        .refreshable { await library.refresh() }
        .task { await library.refresh() }
        .confirmationDialog("Unpublish Clip?", isPresented: Binding(get: { clipToUnpublish != nil }, set: { if !$0 { clipToUnpublish = nil } })) {
            Button("Unpublish", role: .destructive) {
                if let clip = clipToUnpublish { Task { await library.toggleClipPublication(clip) } }
                clipToUnpublish = nil
            }
            Button("Cancel", role: .cancel) { clipToUnpublish = nil }
        }
        .confirmationDialog("Delete Download?", isPresented: Binding(get: { deleteID != nil }, set: { if !$0 { deleteID = nil } })) {
            Button("Delete Download", role: .destructive) { if let deleteID { library.downloads.delete(deleteID) }; deleteID = nil }
            Button("Cancel", role: .cancel) { deleteID = nil }
        }
    }
}
