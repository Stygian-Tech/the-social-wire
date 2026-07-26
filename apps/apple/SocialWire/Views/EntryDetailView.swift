import SwiftUI

struct EntryDetailView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.openURL) private var openURL
    let entry: EntryDetail
    @State private var quoteText = ""
    @State private var replyText = ""
    @State private var showingQuote = false
    @State private var showingReply = false

    private var presentationMode: ArticlePresentationMode? {
        ArticlePresentationResolver.lockedPresentation(
            entryId: entry.entryId,
            contentHtml: entry.contentHtml,
            embedUrl: entry.embedUrl,
            originalUrl: entry.originalUrl
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.title)
                        .font(.title2.weight(.semibold))
                    Text(Self.formatted(entry.publishedAt))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                ArticleToolbar(
                    entry: entry,
                    showingQuote: $showingQuote,
                    showingReply: $showingReply
                )

                Divider()
            }
            .padding(.horizontal)
            .padding(.top)

            articleBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Article")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingQuote) {
            composeSheet(title: "Quote Post", text: $quoteText) {
                try await appModel.quoteEntry(entry, text: quoteText)
                quoteText = ""
                showingQuote = false
            }
        }
        .sheet(isPresented: $showingReply) {
            composeSheet(title: "Reply", text: $replyText) {
                try await appModel.replyToEntry(entry, text: replyText)
                replyText = ""
                showingReply = false
            }
        }
    }

    @ViewBuilder
    private var articleBody: some View {
        switch presentationMode {
        case .html:
            HTMLWebView(html: entry.contentHtml, baseURL: entry.canonicalURL)
                .accessibilityLabel("Article content")
                .id(entry.entryId)
        case .webPreview:
            if let url = entry.canonicalURL {
                WebPreview(url: url)
                    .accessibilityLabel("Article content")
            } else {
                emptyBody
            }
        case nil:
            emptyBody
        }
    }

    @ViewBuilder
    private var emptyBody: some View {
        if let url = entry.canonicalURL {
            Button {
                openURL(url)
            } label: {
                Label("Open Original Article", systemImage: "safari")
            }
            .buttonStyle(.borderedProminent)
            .padding()
        } else {
            ContentUnavailableView("No Article Body", systemImage: "doc.text")
        }
    }

    @ViewBuilder
    private func composeSheet(title: String, text: Binding<String>, onPost: @escaping () async throws -> Void) -> some View {
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
                                appModel.errorMessage = "Couldn't post your \(title == "Quote Post" ? "quote" : "reply"). \(error.localizedDescription)"
                            }
                        }
                    }
                    .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private static func formatted(_ raw: String) -> String {
        guard let date = DateFormatters.date(from: raw) else { return raw }
        return date.formatted(date: .long, time: .omitted)
    }
}
