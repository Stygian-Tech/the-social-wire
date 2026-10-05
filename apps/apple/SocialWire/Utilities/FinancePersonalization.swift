import Foundation

enum FinancePersonalization {
    static func reorder(_ items: [FinanceFeedItem], selections: [FinanceSelectionRecord]) -> [FinanceFeedItem] {
        let instruments = Set(selections.filter { $0.kind == "instrument" }.map(\.reference))
        let sectors = Set(selections.filter { $0.kind == "sector" }.map(\.reference))
        // Server order is the baseline. Immediate local adaptation is provisional
        // until a refreshed immutable server generation replaces these rows.
        var remaining = items.enumerated().sorted { lhs, rhs in
            func score(_ pair: (offset: Int, element: FinanceFeedItem)) -> Double {
                let item = pair.element
                let instrument = item.instruments.contains { instruments.contains($0.instrument.id) }
                let sector = item.sectorIDs.contains { sectors.contains($0) }
                let boost = min(0.35, (instrument ? 0.25 : 0) + (sector ? 0.1 : 0))
                return (1 - Double(pair.offset) / Double(max(1, items.count)) * 0.5) * (1 + boost)
            }
            return score(lhs) > score(rhs)
        }.map(\.element)
        var ordered: [FinanceFeedItem] = []
        while !remaining.isEmpty {
            let index = ordered.count % 5 == 4
                ? remaining.firstIndex(where: \.majorGlobal) ?? 0 : 0
            ordered.append(remaining.remove(at: index))
        }
        return ordered
    }

    static func containsCashtag(_ symbol: String, in text: String) -> Bool {
        let pattern = "(?i)(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: "$" + symbol) + "(?![A-Za-z0-9.])"
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    static func insertingCashtag(_ symbol: String, into text: String) -> String {
        guard symbol.range(of: "^[A-Za-z0-9][A-Za-z0-9.]{0,19}$", options: .regularExpression) != nil else { return text }
        let tag = "$" + symbol
        guard !containsCashtag(symbol, in: text) else { return text }
        let result = text.isEmpty ? tag : text + (text.last?.isWhitespace == true ? "" : " ") + tag
        return result.count <= 300 ? result : text
    }
}
