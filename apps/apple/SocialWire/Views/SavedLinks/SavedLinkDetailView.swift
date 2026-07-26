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
                        .accessibilityLabel("Article content")
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
                    .accessibilityLabel("Compose \(title)")
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
