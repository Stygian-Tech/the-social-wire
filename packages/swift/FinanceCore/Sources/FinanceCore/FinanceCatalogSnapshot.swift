import Foundation

public struct FinanceCatalogSnapshot: Codable, Equatable, Sendable {
  public let version: String
  public let generatedAt: Date
  public let instruments: [FinanceInstrument]
  public init(version: String, generatedAt: Date, instruments: [FinanceInstrument]) {
    self.version = version; self.generatedAt = generatedAt; self.instruments = instruments
  }
}
