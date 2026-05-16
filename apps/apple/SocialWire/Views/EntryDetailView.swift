import SwiftUI

struct EntryDetailView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    let entry: EntryDetail
    @State private var quoteText = ""
    @State private var showingQuote = false

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

                ArticleToolbar(entry: entry, showingQuote: $showingQuote)
                    .padding(.horizontal)

                Divider()

                if !entry.contentHtml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    HTMLWebView(html: HTMLRenderer.wrappedHTML(entry.contentHtml))
                        .frame(minHeight: 520)
                } else if let url = entry.canonicalURL {
                    Link(destination: url) {
                        Label("Open Original Article", systemImage: "safari")
                    }
                    .padding()
                } else {
                    ContentUnavailableView("No Article Body", systemImage: "doc.text")
                }
            }
        }
        .navigationTitle("Article")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingQuote) {
            NavigationStack {
                Form {
                    TextEditor(text: $quoteText)
                        .frame(minHeight: 160)
                }
                .navigationTitle("Quote Post")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingQuote = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Post") {
                            Task {
                                await appModel.quoteCurrentEntry(text: quoteText)
                                quoteText = ""
                                showingQuote = false
                            }
                        }
                        .disabled(quoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
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

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    Task { await appModel.saveCurrentEntry() }
                } label: {
                    Label("Save", systemImage: "bookmark")
                }
                .buttonStyle(.bordered)
                .disabled(entry.canonicalURL == nil)

                Button {
                    showingQuote = true
                } label: {
                    Label("Quote", systemImage: "quote.bubble")
                }
                .buttonStyle(.bordered)

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
