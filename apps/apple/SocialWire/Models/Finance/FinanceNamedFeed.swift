import Foundation

struct FinanceNamedFeed: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let kind: String
    let instrumentIDs: [String]
    let sectorIDs: [String]
    let description: String
    var assetKind: String? = nil

    var pickerGroup: String {
        switch assetKind {
        case "stock": "Stocks"
        case "etf": "ETFs"
        case "crypto": "Crypto"
        case "index": "Indices"
        case "commodity": "Commodities"
        default: kind == "sector" ? "Industries" : "Finance"
        }
    }

    var systemImage: String {
        switch assetKind {
        case "etf": "square.stack.3d.up"
        case "crypto": "bitcoinsign.circle"
        case "index": "chart.bar.xaxis"
        case "commodity": "shippingbox"
        default: "chart.line.uptrend.xyaxis"
        }
    }

    func isVisible(hideCrypto: Bool) -> Bool {
        !hideCrypto || assetKind != "crypto"
    }

    func resolvedInstrument(metadata: [String: FinanceInstrument], items: [FinanceFeedItem]) -> FinanceInstrument? {
        guard kind == "instrument", instrumentIDs.count == 1, let reference = instrumentIDs.first else { return nil }
        if let instrument = metadata[reference], instrument.id == reference { return instrument }
        return items.lazy.flatMap(\.instruments)
            .first { $0.instrument.id == reference && $0.confidenceBps >= 9000 }?.instrument
    }

    func matchesSearch(_ query: String) -> Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "$"))
        return text.isEmpty || title.localizedCaseInsensitiveContains(text)
            || description.localizedCaseInsensitiveContains(text)
    }

    static let all = FinanceNamedFeed(id: "finance", title: "All Finance", kind: "all",
                                     instrumentIDs: [], sectorIDs: [], description: "Global Finance Coverage")
}
