import SwiftUI

struct FinanceNewsView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var scrollAnchor: String?
    @State private var showingFeedPicker = false
    @State private var showingCustomization = false
    let sceneModel: NewsSceneModel

    private var visibleFeeds: [FinanceNamedFeed] {
        appModel.financeFeeds.filter {
            $0.isVisible(hideCrypto: appModel.feedPreferences.hideFinanceCrypto)
        }
    }

    private var tickerInstruments: [FinanceInstrument] {
        var seen = Set<String>()
        let storyInstruments = appModel.financeItems
            .flatMap(\.instruments)
            .map(\.instrument)
        return (Array(appModel.financeInstrumentMetadata.values) + storyInstruments)
            .filter { seen.insert($0.id).inserted }
            .filter { $0.tradingViewSymbol != nil }
            .sorted { $0.symbol.localizedStandardCompare($1.symbol) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if !tickerInstruments.isEmpty {
                    FinanceMarketTickerStrip(instruments: tickerInstruments)
                }
                FinanceFeedStrip(
                    feeds: visibleFeeds,
                    instruments: appModel.financeInstrumentMetadata,
                    selectedFeedID: appModel.selectedFinanceFeedID,
                    onSelect: { feed in
                        Task { await appModel.selectFinanceFeed(feed.id) }
                    }
                )
                HStack {
                    Button("Choose Feed", systemImage: "line.3.horizontal.decrease") {
                        showingFeedPicker = true
                    }
                    .accessibilityValue(appModel.selectedFinanceFeed.title)
                    Spacer()
                    Button("Customize", systemImage: "slider.horizontal.3") { showingCustomization = true }
                }
                if appModel.selectedFinanceFeedID != "finance" {
                    Text("Only Stories Matching This Feed").font(.caption).foregroundStyle(.secondary)
                }
                if let instrument = appModel.selectedFinanceFeed.resolvedInstrument(
                    metadata: appModel.financeInstrumentMetadata, items: appModel.financeItems
                ) {
                    FinanceInstrumentOverview(instrument: instrument,
                        hidePerformance: appModel.feedPreferences.hideFinancePerformance,
                        widgetsEnabled: appModel.financePage?.widgetsEnabled == true,
                        items: appModel.financeItems)
                    Text("Latest News").font(.title2.bold())
                }
                if let error = appModel.financeError {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                    Button("Retry") { Task { await appModel.loadFinance() } }
                }
                if appModel.isLoadingFinance, appModel.financeItems.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 180)
                } else if appModel.financeItems.isEmpty {
                    ContentUnavailableView("No Matching Stories Yet", systemImage: "chart.line.uptrend.xyaxis",
                        description: Text(appModel.selectedFinanceFeedID == "finance"
                            ? "Finance Stories Will Appear Here When Available."
                            : "No Validated Stories Currently Match This Feed."))
                }
                EditorialCardLayout(
                    spacing: 18,
                    minimumCardWidth: dynamicTypeSize.isAccessibilitySize
                        ? ArticleReadingWidth.editorial
                        : 280
                ) {
                    ForEach(appModel.financeItems) { item in
                        WireStoryCard(entry: item.story.toEntryListItem()) { open(item) }
                            .id(item.id)
                    }
                }
                if appModel.financeContinuationSuspended {
                    Button("Refresh Personalized Feed") { Task { await appModel.loadFinance() } }
                } else if let cursor = appModel.financePage?.cursor {
                    Button("More Stories") { Task { await appModel.loadFinance(cursor: cursor) } }
                        .disabled(appModel.isLoadingFinance)
                }
            }
            .scrollTargetLayout()
            .padding()
            .frame(maxWidth: ArticleReadingWidth.editorial)
            .frame(maxWidth: .infinity)
        }
        .scrollPosition(id: $scrollAnchor)
        .refreshable { await appModel.loadFinance() }
        .onChange(of: appModel.selectedFinanceFeedID) { _, _ in scrollAnchor = nil }
        .sheet(isPresented: $showingFeedPicker) { FinanceFeedPickerView() }
        .sheet(isPresented: $showingCustomization) { FinanceCustomizationView() }
    }

    private func open(_ item: FinanceFeedItem) {
        guard let url = URL(string: item.story.canonicalUrl) else { return }
        openURL(url)
    }
}

private struct FinanceFeedStrip: View {
    let feeds: [FinanceNamedFeed]
    let instruments: [String: FinanceInstrument]
    let selectedFeedID: String
    let onSelect: (FinanceNamedFeed) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 8) {
                ForEach(feeds) { feed in
                    Button {
                        onSelect(feed)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(feed.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            if let symbol = tickerSymbol(for: feed) {
                                Text(symbol)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            selectedFeedID == feed.id ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08),
                            in: .rect(cornerRadius: 10)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedFeedID == feed.id ? .isSelected : [])
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func tickerSymbol(for feed: FinanceNamedFeed) -> String? {
        guard feed.kind == "instrument", let instrumentID = feed.instrumentIDs.first else { return nil }
        return instruments[instrumentID]?.symbol
    }
}

private struct FinanceMarketTickerStrip: View {
    let instruments: [FinanceInstrument]

    var body: some View {
        ScrollView(.horizontal) {
            LazyHGrid(
                rows: [GridItem(.fixed(142)), GridItem(.fixed(142))],
                alignment: .top,
                spacing: 10
            ) {
                ForEach(instruments) { instrument in
                    tickerCard(instrument)
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        .accessibilityLabel("Market Tickers")
    }

    private func tickerCard(_ instrument: FinanceInstrument) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(instrument.symbol)
                    .font(.subheadline.monospaced().weight(.semibold))
                Text(instrument.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let symbol = instrument.tradingViewSymbol {
                TradingViewFinanceWidget(
                    symbol: symbol,
                    height: 96,
                    automaticallyLoads: true,
                    chartOnly: true
                )
                .allowsHitTesting(false)
            }
        }
        .padding(8)
        .frame(width: 240, height: 142, alignment: .topLeading)
        .background(.thinMaterial, in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}
