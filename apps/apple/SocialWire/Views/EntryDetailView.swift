import SwiftUI

struct EntryDetailView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    let entry: EntryDetail

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

                ArticleToolbar(entry: entry)

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

    private static func formatted(_ raw: String) -> String {
        guard let date = DateFormatters.date(from: raw) else { return raw }
        return date.formatted(date: .long, time: .omitted)
    }
}
