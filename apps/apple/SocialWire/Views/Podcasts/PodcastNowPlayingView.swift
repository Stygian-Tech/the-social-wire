import SwiftUI

struct PodcastNowPlayingView: View {
    @Environment(PodcastLibraryModel.self) private var library
    @State private var query = ""
    @State private var clipPresented = false

    var body: some View {
        List {
            if let episode = library.player.episode {
                Section {
                    Text(episode.title).font(.title2)
                    if let description = episode.description { Text(description).font(.subheadline) }
                    Toggle("Remove Silences", isOn: Binding(get: { episode.permitsPublicProcessing && library.player.removesSilence }, set: { value in Task { await library.setRemoveSilences(value) } }))
                        .disabled(!episode.permitsPublicProcessing)
                    if !episode.permitsPublicProcessing { Text("Private episodes support playback and device downloads. Public clips and silence analysis are unavailable.").font(.caption).foregroundStyle(.secondary) }
                    if library.processingSilence { ProgressView("Analyzing Silences") }
                    if let error = library.error { Text(error).font(.caption).foregroundStyle(.red) }
                    Button("Create Clip", systemImage: "scissors") { clipPresented = true }
                        .disabled(!episode.permitsPublicProcessing)
                }
                Section("Transcript") {
                    let cues = library.transcript.flatMap(\.cues).filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) }
                    if cues.isEmpty {
                        ForEach(library.transcript.filter { $0.text != nil }, id: \.url) { transcript in
                            Text(transcript.text ?? "")
                        }
                        if library.transcript.isEmpty { Text("No Transcript Available").foregroundStyle(.secondary) }
                    }
                    ForEach(cues, id: \.self) { cue in
                        Button { library.player.seek(cue.startSeconds) } label: {
                            HStack(alignment: .top) {
                                Text(PodcastPlayerView.time(cue.startSeconds)).font(.caption).monospacedDigit()
                                Text(cue.text).foregroundStyle(.primary)
                            }
                        }
                        .accessibilityLabel("Seek to \(PodcastPlayerView.time(cue.startSeconds)): \(cue.text)")
                    }
                }
            }
        }
        .navigationTitle("Now Playing")
        .searchable(text: $query, prompt: "Search Transcript")
        .sheet(isPresented: $clipPresented) { NavigationStack { PodcastClipEditorView() } }
    }
}
