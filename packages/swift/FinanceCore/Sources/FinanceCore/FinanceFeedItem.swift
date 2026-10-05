import WireCore

public struct FinanceFeedItem: Codable, Equatable, Sendable {
  public let story: WireFeedItem
  public let instruments: [FinanceMatchedInstrument]
  public let macroTopics: [String]?
  public let sectorIDs: [String]
  public let majorGlobal: Bool
  public let materiality: String
  public init(story: WireFeedItem, instruments: [FinanceMatchedInstrument], sectorIDs: [String] = [], materiality: String = "reporting", majorGlobal: Bool = false, macroTopics: [String] = []) {
    self.majorGlobal = majorGlobal; self.story = story; self.instruments = instruments; self.sectorIDs = sectorIDs; self.materiality = materiality; self.macroTopics = macroTopics
  }
}
