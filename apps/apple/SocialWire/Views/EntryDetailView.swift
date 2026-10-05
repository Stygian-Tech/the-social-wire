import SwiftUI

struct EntryDetailView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    let entry: EntryDetail
    @State private var selectedCashtags: Set<String> = []
    @State private var quoteText = ""
    @State private var replyText = ""
    @State private var showingQuote = false
    @State private var showingReply = false

    private var financeSuggestions: [FinanceInstrument] {
        entry.financeInstruments ?? appModel.financeSuggestions(for: entry.entryId)
    }

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

                if !appModel.feedPreferences.hideFinancePerformance,
                   appModel.financePage?.widgetsEnabled == true,
                   let symbol = financeSuggestions.first?.tradingViewSymbol,
                   ProcessInfo.processInfo.environment["FINANCE_WIDGETS_DISABLED"] != "true" {
                    TradingViewFinanceWidget(symbol: symbol)
                        .id(symbol)
                }
                Divider()
            }
            .padding(.horizontal)
            .padding(.top)

            articleBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Article")
        .platformInlineNavigationTitle()
        .sheet(isPresented: $showingQuote) {
            composeSheet(title: "Quote Post", text: $quoteText) {
                try await appModel.quoteEntry(entry, text: quoteText)
                await appModel.recordFinanceComposition(event: "published", count: financeSuggestions.count)
                quoteText = ""
                selectedCashtags = []
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
                ArticleBodyUnavailableView(originalURL: nil)
            }
        case nil:
            ArticleBodyUnavailableView(originalURL: entry.canonicalURL)
        }
    }

    @ViewBuilder
    private func composeSheet(title: String, text: Binding<String>, onPost: @escaping () async throws -> Void) -> some View {
        NavigationStack {
            Form {
                if title == "Quote Post" {
                    ForEach(financeSuggestions) { instrument in
                        Button("$" + instrument.symbol) {
                            let previous = text.wrappedValue
                            text.wrappedValue = FinancePersonalization.insertingCashtag(instrument.symbol, into: previous)
                            if previous != text.wrappedValue {
                                selectedCashtags.insert(instrument.symbol)
                                Task { await appModel.recordFinanceComposition(event: "selection", count: financeSuggestions.count) }
                            }
                        }
                    }
                }
                TextEditor(text: text)
                    .frame(minHeight: 160)
                    .accessibilityLabel("Compose \(title)")
            }
            .navigationTitle(title)
            .task {
                if title == "Quote Post" { await appModel.recordFinanceComposition(event: "impression", count: financeSuggestions.count) }
            }
            .onChange(of: text.wrappedValue) { _, newValue in
                guard title == "Quote Post" else { return }
                for symbol in selectedCashtags where !FinancePersonalization.containsCashtag(symbol, in: newValue) {
                    selectedCashtags.remove(symbol)
                    Task { await appModel.recordFinanceComposition(event: "removal", count: financeSuggestions.count) }
                }
            }
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
                    .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.wrappedValue.count > 300)
                }
            }
        }
    }

    private static func formatted(_ raw: String) -> String {
        guard let date = DateFormatters.date(from: raw) else { return raw }
        return date.formatted(date: .long, time: .omitted)
    }
}
