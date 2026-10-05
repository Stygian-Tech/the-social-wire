import SwiftUI

struct FinanceInstrumentOverview: View {
    let instrument: FinanceInstrument
    let hidePerformance: Bool
    let widgetsEnabled: Bool
    let items: [FinanceFeedItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(instrument.name, systemImage: "chart.line.uptrend.xyaxis")
                .font(.headline)
            Text([instrument.symbol, instrument.exchangeLabel, instrument.currency, instrument.kind.capitalized]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            if !instrument.isActive {
                Text("Inactive Instrument").font(.caption).foregroundStyle(.secondary)
            }
            if !hidePerformance {
                if widgetsEnabled, let symbol = instrument.tradingViewSymbol,
                   ProcessInfo.processInfo.environment["FINANCE_WIDGETS_DISABLED"] != "true" {
                    TradingViewFinanceWidget(symbol: symbol).id(symbol)
                } else {
                    Text("Market Performance Is Unavailable").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Text("Earnings And Reports").font(.headline)
            Text("Related Reporting From This Feed. Verified Company Report And Earnings-Call Links Are Not Available Yet.")
                .font(.footnote).foregroundStyle(.secondary)
            let coverage = FinanceFeedItem.reportCoverage(in: items, instrumentID: instrument.id)
            if coverage.isEmpty {
                Text("No Earnings Or Filing Coverage In The Loaded Articles.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(coverage) { item in
                if let url = URL(string: item.story.canonicalUrl) {
                    VStack(alignment: .leading, spacing: 4) {
                        Link(item.story.title, destination: url).font(.subheadline)
                        Text("\(item.materiality == "filing" ? "Filing Coverage" : "Earnings Coverage") · \(url.host ?? "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 16))
    }
}
