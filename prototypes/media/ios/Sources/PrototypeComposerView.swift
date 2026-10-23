import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct PrototypeComposerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = "A little moment worth sharing."
    @State private var altText = ""
    @State private var attached = false
    @State private var player: AVPlayer?
    @State private var previewing = false
    @State private var importing = false
    @State private var loading = false
    @State private var error: String?
    @State private var filename = "flower.mp4 · Sample Video"
    @State private var importedURL: URL?
    @State private var generation = UUID()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Label("Bluesky Post", systemImage: "bubble.left.and.text.bubble.right")
                        .font(.headline)
                    Text("Prototype · Local Preview Only").font(.caption).foregroundStyle(.secondary)
                    if previewing {
                        Text(text.isEmpty ? "Video Post" : text).font(.body)
                    } else {
                        TextEditor(text: $text)
                            .frame(minHeight: 130)
                            .padding(8)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityLabel("Post Text")
                    }
                    if attached {
                        VideoPlayer(player: player)
                            .frame(height: 260)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .accessibilityLabel("Attached Video Preview")
                        Label(filename, systemImage: "video")
                            .font(.caption).foregroundStyle(.secondary)
                        if previewing {
                            if !altText.isEmpty { Text("Video Description: \(altText)").font(.caption) }
                        } else {
                            TextField("Describe the Video for Accessibility", text: $altText, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Video Description")
                            Button("Remove Video", systemImage: "trash", role: .destructive) {
                                removeVideo()
                            }
                        }
                    } else if !previewing {
                        Button("Attach Sample Video", systemImage: "video.badge.plus") {
                            if let url = Bundle.main.url(forResource: "flower", withExtension: "mp4") {
                                removeVideo()
                                filename = "flower.mp4 · Sample Video"
                                setPlayer(url)
                            }
                        }.buttonStyle(.bordered).disabled(loading)
                        Button("Attach Video from Files", systemImage: "folder") { importing = true }
                            .disabled(loading)
                    }
                    if loading { ProgressView("Checking Video…") }
                    if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                    if !previewing { Text("\(text.count) / 300").font(.caption).foregroundStyle(.secondary) }
                    if previewing {
                        Label("Preview Ready — Nothing Was Published", systemImage: "checkmark.circle")
                            .font(.subheadline).foregroundStyle(.purple)
                        Text("The text, video, and description stay in this prototype. No upload or Bluesky post is created.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("Continue Editing") { previewing = false }
                    } else {
                        Text("Choose one MP4, up to 300 MB and 10 minutes, or try the bundled clip. Uploading and publishing are not connected.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }.padding()
            }
            .navigationTitle(previewing ? "Post Preview" : "New Post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                if !previewing {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Preview Post") { previewing = true }
                            .disabled(loading || text.count > 300 || text.utf8.count > 3000 || (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !attached))
                    }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.mpeg4Movie]) { result in
                if case .success(let url) = result { Task { await importVideo(url) } }
                if case .failure(let failure) = result { error = failure.localizedDescription }
            }
            .onDisappear { removeVideo() }
        }
    }
    private func setPlayer(_ url: URL) {
        let playback = AVPlayer(url: url)
        playback.isMuted = true
        player = playback
        attached = true
        playback.play()
    }
    private func removeVideo() {
        generation = UUID()
        player?.pause()
        player = nil
        attached = false
        loading = false
        altText = ""
        error = nil
        if let importedURL { try? FileManager.default.removeItem(at: importedURL) }
        importedURL = nil
    }
    private func importVideo(_ url: URL) async {
        removeVideo()
        let owner = generation
        loading = true
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= 300_000_000 else { throw CocoaError(.fileReadTooLarge) }
            try FileManager.default.copyItem(at: url, to: temporary)
            let seconds = try await AVURLAsset(url: temporary).load(.duration).seconds
            guard generation == owner else { try? FileManager.default.removeItem(at: temporary); return }
            guard seconds.isFinite, seconds > 0, seconds <= 600 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            importedURL = temporary
            filename = url.lastPathComponent
            loading = false
            setPlayer(temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            guard generation == owner else { return }
            loading = false
            self.error = "Choose a playable MP4 of at most 300 MB and 10 minutes."
        }
    }

}
