import SwiftUI

struct SavedLinkDetailView: View {
    @Environment(SocialWireAppModel.self) private var appModel

    let save: MergedLatrSave
    @State private var socialEntry: EntryDetail?
    @State private var isLoadingSocialEntry = false
    @State private var quoteText = ""
    @State private var replyText = ""
    @State private var showingQuote = false
    @State private var showingReply = false

    private var isArchivedView: Bool {
        appModel.readerListSource == .archive || save.state == "archived"
    }

    private var previewURL: URL? {
        SavedLinkEmbedURL.previewURL(for: save)
    }

    var body: some View {
        Group {
            if let url = previewURL {
                VStack(spacing: 0) {
                    SavedLinkToolbar(
                        save: save,
                        entry: socialEntry,
                        isArchivedView: isArchivedView,
                        showingQuote: $showingQuote,
                        showingReply: $showingReply
                    )
                    .padding(.horizontal)
                    .padding(.vertical, 8)

                    WebPreview(url: url)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView(
                    "Preview Unavailable",
                    systemImage: "archivebox",
                    description: Text("This saved item does not have a readable web URL yet.")
                )
            }
        }
        .task(id: save.id) {
            await loadSocialEntry()
        }
        .sheet(isPresented: $showingQuote) {
            socialComposeSheet(title: "Quote Post", text: $quoteText) {
                guard let entry = socialEntry else { return }
                try await appModel.quoteEntry(entry, text: quoteText)
                quoteText = ""
                showingQuote = false
            }
        }
        .sheet(isPresented: $showingReply) {
            socialComposeSheet(title: "Reply", text: $replyText) {
                guard let entry = socialEntry else { return }
                try await appModel.replyToEntry(entry, text: replyText)
                replyText = ""
                showingReply = false
            }
        }
    }

    @ViewBuilder
    private func socialComposeSheet(
        title: String,
        text: Binding<String>,
        onPost: @escaping () async throws -> Void
    ) -> some View {
        NavigationStack {
            Form {
                TextEditor(text: text)
                    .frame(minHeight: 160)
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if title == "Quote Post" {
                            showingQuote = false
                        } else {
                            showingReply = false
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Post") {
                        Task {
                            do {
                                try await onPost()
                            } catch {
                                appModel.errorMessage = error.localizedDescription
                            }
                        }
                    }
                    .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func loadSocialEntry() async {
        isLoadingSocialEntry = true
        defer { isLoadingSocialEntry = false }
        socialEntry = await appModel.savedLinkSocialEntry(for: save)
    }
}

struct SavedLinkToolbar: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.openURL) private var openURL

    let save: MergedLatrSave
    let entry: EntryDetail?
    let isArchivedView: Bool
    @Binding var showingQuote: Bool
    @Binding var showingReply: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let url = SavedLinkEmbedURL.previewURL(for: save) {
                    ShareLink(item: url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        openURL(url)
                    } label: {
                        Label("Open", systemImage: "safari")
                    }
                    .buttonStyle(.bordered)
                }

                Button {
                    showingQuote = true
                } label: {
                    Label("Quote", systemImage: "quote.bubble")
                }
                .buttonStyle(.bordered)

                if entry?.bskyPostUri != nil {
                    Button {
                        Task { await appModel.likeEntry(entry!) }
                    } label: {
                        Label("Like", systemImage: "heart")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        Task { await appModel.repostEntry(entry!) }
                    } label: {
                        Label("Repost", systemImage: "repeat")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        showingReply = true
                    } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                    }
                    .buttonStyle(.bordered)
                }

                if isArchivedView {
                    Button {
                        Task { await appModel.unarchive(save) }
                    } label: {
                        Label("Unarchive", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        Task { await appModel.archive(save) }
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                    .buttonStyle(.bordered)
                }

                Button(role: .destructive) {
                    Task { await appModel.delete(save) }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.bordered)
            }
        }
    }
}
