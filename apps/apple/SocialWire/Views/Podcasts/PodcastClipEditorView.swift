import SwiftUI

struct PodcastClipEditorView: View {
    @Environment(PodcastLibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var start = 0.0
    @State private var end = 60.0
    @State private var includeCaptions = true
    @State private var title = ""

    var body: some View {
        Form {
            Section("Clip Range") {
                TextField("Clip Title", text: $title)
                Stepper("Start: \(PodcastPlayerView.time(start))", value: $start, in: 0...max(1, library.player.duration), step: 1)
                Stepper("End: \(PodcastPlayerView.time(end))", value: $end, in: 0...max(1, library.player.duration), step: 1)
                Toggle("Include Captions", isOn: $includeCaptions)
                Button("Preview Clip", systemImage: "play") { library.previewClip(start: start, end: end) }
                    .disabled(!validRange)
                Button("Prepare Clip", systemImage: "scissors") { Task { await library.prepareClip(start: start, end: end, title: title, includeCaptions: includeCaptions) } }
                    .disabled(!validRange || library.preparingClip)
                Text("Clips Must Be Between 1 and 600 Seconds").font(.caption).foregroundStyle(.secondary)
            }
            if let status = library.clipStatus { Text(status) }
            if let error = library.error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("Create Clip")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        .onAppear {
            start = library.player.position
            end = min(start + 60, library.player.duration)
            title = library.player.episode?.title ?? ""
        }
    }
    private var validRange: Bool { start >= 0 && end > start && end - start <= 600 && end <= library.player.duration }
}
