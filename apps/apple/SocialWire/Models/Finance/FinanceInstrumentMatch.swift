import Foundation

struct FinanceInstrumentMatch: Codable, Equatable, Sendable {
    let instrument: FinanceInstrument
    let confidenceBps: Int
    let prominence: Double
}
