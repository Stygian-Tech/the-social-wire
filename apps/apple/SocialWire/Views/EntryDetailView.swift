import SwiftUI

struct EntryDetailView: View {
    @Environment(SocialWireAppModel.self) private var appModel
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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.title)
                        .font(.title.bold())
                    Text(Self.formatted(entry.publishedAt))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.top)

                ArticleToolbar(
                    entry: entry,
                    showingQuote: $showingQuote,
                    showingReply: $showingReply
                )
                .padding(.horizontal)

                Divider()

                articleBody
            }
        }
        .navigationTitle("Article")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingQuote) {
            composeSheet(title: "Quote Post", text: $quoteText) {
                await appModel.quoteCurrentEntry(text: quoteText)
                quoteText = ""
                showingQuote = false
            }
        }
        .sheet(isPresented: $showingReply) {
            composeSheet(title: "Reply", text: $replyText) {
                await appModel.replyToCurrentEntry(text: replyText)
                replyText = ""
                showingReply = false
            }
        }
    }

    @ViewBuilder
    private var articleBody: some View {
        switch presentationMode {
        case .html:
            HTMLWebView(html: HTMLRenderer.wrappedHTML(entry.contentHtml))
                .frame(minHeight: 520)
        case .webPreview:
            if let url = entry.canonicalURL {
                WebPreview(url: url)
                    .frame(minHeight: 520)
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
            Link(destination: url) {
                Label("Open Original Article", systemImage: "safari")
            }
            .padding()
        } else {
            ContentUnavailableView("No Article Body", systemImage: "doc.text")
        }
    }

    @ViewBuilder
    private func composeSheet(title: String, text: Binding<String>, onPost: @escaping () async -> Void) -> some View {
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
                        Task { await onPost() }
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

struct ArticleToolbar: View {
    @Environment(SocialWireAppModel.self) private var appModel
    let entry: EntryDetail
    @Binding var showingQuote: Bool
    @Binding var showingReply: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    Task { await appModel.saveCurrentEntry() }
                } label: {
                    Label("Save", systemImage: "bookmark")
                }
                .buttonStyle(.bordered)

                Button {
                    showingQuote = true
                } label: {
                    Label("Quote", systemImage: "quote.bubble")
                }
                .buttonStyle(.bordered)

                if entry.bskyPostUri != nil {
                    Button {
                        showingReply = true
                    } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                    }
                    .buttonStyle(.bordered)
                }

                if let url = entry.canonicalURL {
                    ShareLink(item: url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)

                    Link(destination: url) {
                        Label("Open", systemImage: "safari")
                    }
                    .buttonStyle(.bordered)
                }

                Button {
                    Task { await appModel.likeCurrentEntry() }
                } label: {
                    Label("Like", systemImage: "heart")
                }
                .buttonStyle(.bordered)
                .disabled(entry.bskyPostUri == nil)

                Button {
                    Task { await appModel.repostCurrentEntry() }
                } label: {
                    Label("Repost", systemImage: "repeat")
                }
                .buttonStyle(.bordered)
                .disabled(entry.bskyPostUri == nil)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
