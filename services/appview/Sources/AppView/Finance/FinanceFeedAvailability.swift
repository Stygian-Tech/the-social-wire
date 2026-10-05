import FinanceCore
import Foundation
import WireCore

struct FinanceFeedAvailability: Codable, Sendable {
  let enabled: Bool
  let available: Bool
  let widgetsEnabled: Bool
  var feeds: [FinanceFeedDefinition] = []
}

struct FinanceCombinedCatalog: Encodable {
  let enabled: Bool
  let available: Bool
  let title: String
  let subtitle: String
  let supportedLanguages: [String]
  let latestGenerationId: String?
  let generatedAt: Date?
  let financeAvailable: Bool
  let finance: FinanceFeedAvailability
  let sportsAvailable: Bool
  let sports: SportsFeedAvailability

  init(wire: WireFeedCatalog, wireVisible: Bool = true, finance: FinanceFeedAvailability, sports: SportsFeedAvailability = .init(enabled: false, available: false, eventsEnabled: false)) {
    enabled = wireVisible && wire.enabled; available = wireVisible && wire.available; title = wire.title; subtitle = wire.subtitle
    supportedLanguages = wire.supportedLanguages; latestGenerationId = wire.latestGenerationID
    generatedAt = wire.generatedAt; financeAvailable = finance.available; self.finance = finance
    sportsAvailable = sports.available; self.sports = sports
  }
}
