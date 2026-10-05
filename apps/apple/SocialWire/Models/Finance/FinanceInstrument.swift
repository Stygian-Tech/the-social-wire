import Foundation

struct FinanceInstrument: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let symbol: String
    let kind: String
    let providerID: String
    let exchange: String?
    let currency: String?
    let aliases: [String]
    let sectorIDs: [String]
    let tradingViewSymbol: String?
    let isActive: Bool
    var exchangeName: String? = nil

    var exchangeLabel: String? {
        let code = exchange?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = exchangeName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, !name.isEmpty {
            if let code, !code.isEmpty { return "\(name) (\(code))" }
            return name
        }
        guard let code, !code.isEmpty else { return nil }
        return "Exchange: \(code)"
    }
}
