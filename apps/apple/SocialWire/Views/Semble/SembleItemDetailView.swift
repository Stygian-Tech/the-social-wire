import SwiftUI

struct SembleItemDetailView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    let item: SembleCollectionItem
    @State private var showingNoteEditor = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                contributor

                if let image = item.image, let imageURL = URL(string: image) {
                    CachedRemoteImage(urls: [imageURL], maxPixelSize: 1200) {
                        RoundedRectangle(cornerRadius: 16).fill(Color(.tertiarySystemFill))
                    }
                    .scaledToFit()
                    .clipShape(.rect(cornerRadius: 16))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(item.displayTitle)
                        .font(.title2.bold())
                    if let description = item.description, !description.isEmpty {
                        Text(description)
                            .foregroundStyle(.secondary)
                    }
                    if let siteName = item.siteName, !siteName.isEmpty {
                        Label(siteName, systemImage: "globe")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                if let note = item.note {
                    GroupBox("Note") {
                        Text(note.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if !appModel.sembleConnections.isEmpty {
                    GroupBox("Connections") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(appModel.sembleConnections) { connection in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(connection.connectionType ?? "Related")
                                        .font(.headline)
                                    Text(connection.target)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if let note = connection.note, !note.isEmpty { Text(note) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }

                if let rawURL = item.url, let url = URL(string: rawURL) {
                    Link(destination: url) {
                        Label("Open Original", systemImage: "safari")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding()
        }
        .navigationTitle(item.displayTitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingNoteEditor = true
                } label: {
                    Label(canEditNote ? "Edit Note" : "Add Note", systemImage: "note.text.badge.plus")
                }
                .disabled(item.note != nil && !canEditNote)
            }
        }
        .sheet(isPresented: $showingNoteEditor) {
            SembleNoteEditorSheet(initialText: item.note?.text ?? "") { text in
                if canEditNote {
                    await appModel.updateSembleNote(text, on: item)
                } else {
                    await appModel.addSembleNote(text, to: item)
                }
            }
        }
        .task(id: item.id) { await appModel.loadSembleConnections(for: item) }
    }

    private var canEditNote: Bool {
        item.note?.editable == true && item.note?.uri != nil
    }

    private var contributor: some View {
        HStack(spacing: 12) {
            Group {
                if let avatar = item.contributor.avatar, let url = URL(string: avatar) {
                    CachedRemoteImage(urls: [url], maxPixelSize: 96) {
                        Circle().fill(Color(.tertiarySystemFill))
                    }
                    .scaledToFill()
                } else {
                    Circle().fill(Color(.tertiarySystemFill))
                        .overlay { Image(systemName: "person.fill").foregroundStyle(.secondary) }
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(.circle)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.contributor.label).font(.headline)
                Text(item.contributor.did)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
