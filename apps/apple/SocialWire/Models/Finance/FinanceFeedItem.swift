import Foundation

struct FinanceFeedItem: Codable, Equatable, Identifiable, Sendable {
    let story: WireFeedItem
    let instruments: [FinanceInstrumentMatch]
    let sectorIDs: [String]
    let majorGlobal: Bool
    var materiality: String? = nil
    var id: String { story.itemId }
    var suggestions: [FinanceInstrument] {
        Array(instruments.filter { $0.confidenceBps >= 9000 }
            .sorted { $0.prominence < $1.prominence }.map(\.instrument).prefix(3))
    }

    static func reportCoverage(in items: [FinanceFeedItem], instrumentID: String) -> [FinanceFeedItem] {
        var urls = Set<String>()
        return Array(items.filter { item in
            guard ["earnings", "filing"].contains(item.materiality ?? ""),
                  item.instruments.contains(where: { $0.instrument.id == instrumentID && $0.confidenceBps >= 9000 }),
                  let url = URL(string: item.story.canonicalUrl),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return false }
            return urls.insert(item.story.canonicalUrl).inserted
        }.prefix(3))
    }
}
