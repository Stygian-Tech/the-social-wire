#if os(iOS)
import Feeds
import SwiftData
import SwiftUI

struct CashtagCardsView: View {
    let text: String
    let facets: [TimelineFacet]

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @Environment(\.showsInlineStockCharts) private var showsInlineStockCharts
    @Query private var settings: [AppSettings]
    @State private var selectedTicker: String?
    @State private var isVisible = false
    @State private var resolvedStocks: [ResolvedStockTicker] = []
    @State private var validatedCandidates: [String] = []

    var body: some View {
        let candidates = showsInlineStockCharts ? CashtagTickerDetector.tickers(in: text, facets: facets) : []
        // Never reserve a chart page for a lexical candidate before stock validation.
        let stocks = validatedCandidates == candidates ? resolvedStocks : []
        let tickers = stocks.map(\.ticker)
        Group {
            if !tickers.isEmpty {
                VStack(spacing: 6) {
                    HStack(spacing: 12) {
                        Picker("Chart Style", selection: chartStyle) {
                            ForEach(StockChartStyle.allCases) { style in
                                Text(style.title).tag(style)
                            }
                        }
                        .pickerStyle(.segmented)
                        if tickers.count > 1 {
                            Text("\((tickers.firstIndex(of: selection(in: tickers)) ?? 0) + 1) of \(tickers.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                    }

                    TabView(selection: tickerSelection(in: tickers)) {
                        ForEach(stocks, id: \.ticker) { stock in
                            let ticker = stock.ticker
                            Group {
                                if isVisible, scenePhase == .active, ticker == selection(in: tickers) {
                                    TradingViewChartView(configuration: TradingViewChartConfiguration(
                                        symbol: stock.tradingViewSymbol,
                                        style: chartStyle.wrappedValue,
                                        isDark: colorScheme == .dark
                                    ))
                                } else {
                                    Color.clear.overlay { ProgressView("Loading Chart") }
                                }
                            }
                            .tag(ticker)
                            .accessibilityLabel("Chart for \(ticker)")
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .frame(height: TradingViewChartView.height)

                    if tickers.count > 1 {
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) {
                                ForEach(tickers, id: \.self) { ticker in
                                    Button {
                                        selectedTicker = ticker
                                    } label: {
                                        Text(verbatim: "$\(ticker)")
                                            .font(.caption.bold())
                                            .padding(.horizontal, 10)
                                            .frame(minHeight: 44)
                                            .background(
                                                ticker == selection(in: tickers) ? Color.accentColor.opacity(0.15) : Color.clear,
                                                in: .capsule
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Show \(ticker)")
                                    .accessibilityAddTraits(ticker == selection(in: tickers) ? .isSelected : [])
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                    }
                }
                .accessibilityIdentifier("cashtag-stock-cards")
                .onScrollVisibilityChange(threshold: 0.1) { isVisible = $0 }
                .onDisappear { isVisible = false }
                .sensoryFeedback(.selection, trigger: selectedTicker)
                .sensoryFeedback(.selection, trigger: chartStyle.wrappedValue)
            } else {
                // Keep the validation task alive without reserving chart space.
                Color.clear.frame(height: 0).accessibilityHidden(true)
            }
        }
        .task(id: candidates + [scenePhase == .active ? "active" : "inactive"]) {
            resolvedStocks = []
            validatedCandidates = []
            guard scenePhase == .active, !candidates.isEmpty else { return }
            while !Task.isCancelled {
                let stocks = await StockTickerResolver.shared.resolve(candidates)
                guard !Task.isCancelled else { return }
                resolvedStocks = stocks
                validatedCandidates = candidates
                let refreshDelay = await StockTickerResolver.shared.nextRefreshDelay()
                do { try await Task.sleep(for: .seconds(refreshDelay)) }
                catch { return }
                resolvedStocks = []
                validatedCandidates = []
            }
        }
    }

    private var chartStyle: Binding<StockChartStyle> {
        Binding {
            settings.first?.stockChartStyle ?? .line
        } set: { style in
            let value: AppSettings
            if let existing = settings.first { value = existing } else {
                value = AppSettings()
                modelContext.insert(value)
            }
            value.stockChartStyle = style
            try? modelContext.save()
        }
    }

    private func selection(in tickers: [String]) -> String {
        if let selectedTicker, tickers.contains(selectedTicker) { return selectedTicker }
        return tickers[0]
    }

    private func tickerSelection(in tickers: [String]) -> Binding<String> {
        Binding(get: { selection(in: tickers) }, set: { selectedTicker = $0 })
    }
}

#endif
