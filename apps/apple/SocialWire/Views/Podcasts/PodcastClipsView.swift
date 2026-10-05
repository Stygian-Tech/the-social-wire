import SwiftUI

struct PodcastClipsView: View {
    @Environment(PodcastLibraryModel.self) private var library
    @State private var exportedMedia: [String: URL] = [:]
    @State private var exporting = false
    @State private var clipToUnpublish: PodcastClip?

    var body: some View {
        List {
            Section {
                ForEach(library.clips) { clip in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(clip.title).font(.headline)
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
                        if clip.status == "complete" || clip.publishedUri != nil {
                            Button(clip.publishedUri == nil ? "Publish" : "Unpublish") {
                                if clip.publishedUri != nil { clipToUnpublish = clip }
                                else { Task { await library.toggleClipPublication(clip) } }
                            }
                        }
                    }
                }
            } footer: { Text("Clips from public episodes can be exported or published. Private episodes are excluded.") }
            if let error = library.error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("Clips")
        .overlay {
            if library.clips.isEmpty { ContentUnavailableView("No Clips", systemImage: "scissors", description: Text("Create a clip from a public episode in Now Playing.")) }
        }
        .refreshable { await library.refresh() }
        .confirmationDialog("Unpublish Clip?", isPresented: Binding(get: { clipToUnpublish != nil }, set: { if !$0 { clipToUnpublish = nil } })) {
            Button("Unpublish", role: .destructive) {
                if let clip = clipToUnpublish { Task { await library.toggleClipPublication(clip) } }
                clipToUnpublish = nil
            }
            Button("Cancel", role: .cancel) { clipToUnpublish = nil }
        }
    }
}
