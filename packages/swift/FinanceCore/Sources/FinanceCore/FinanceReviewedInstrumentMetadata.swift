/// Version-controlled identity-specific overrides. Entries require coverage/rights and symbol evidence.
/// Reviewed listing-specific interests; an unreviewed exchange/ticker never becomes a display mapping.
public struct FinanceReviewedInstrumentMetadata: Sendable {
  public let instrumentID: String
  public let expectedProviderID: String
  public let expectedSymbol: String
  public let tradingViewSymbol: String?
  public let sectorIDs: [String]
  public let industryIDs: [String]
  public let aliases: [String]
  public let verifiedDomains: [String]
  public let verifiedAccounts: [String]
  public let evidenceURL: String

  public init(instrumentID: String, expectedProviderID: String, expectedSymbol: String,
    tradingViewSymbol: String?, sectorIDs: [String] = [], aliases: [String] = [], evidenceURL: String, verifiedDomains: [String] = [], verifiedAccounts: [String] = [], industryIDs: [String] = []) {
    self.industryIDs = industryIDs; self.instrumentID = instrumentID; self.expectedProviderID = expectedProviderID; self.expectedSymbol = expectedSymbol
    self.tradingViewSymbol = tradingViewSymbol; self.sectorIDs = sectorIDs; self.aliases = aliases; self.evidenceURL = evidenceURL; self.verifiedDomains = verifiedDomains; self.verifiedAccounts = verifiedAccounts
  }
  public static let version = "reviewed-metadata-v4"
  public static let entries: [Self] = [
    .init(instrumentID: FinanceIdentity.instrumentID(provider: "openfigi", nativeID: "BBG000BDTBL9"),
      expectedProviderID: "BBG000BDTBL9", expectedSymbol: "SPY", tradingViewSymbol: nil,
      aliases: ["SPDR S&P 500 ETF"], evidenceURL: "https://www.openfigi.com/id/BBG000BDTBL9"),
    .init(instrumentID: FinanceIdentity.instrumentID(provider: "openfigi", nativeID: "BBG000BSWKH7"),
      expectedProviderID: "BBG000BSWKH7", expectedSymbol: "QQQ", tradingViewSymbol: nil,
      aliases: ["Invesco QQQ"], evidenceURL: "https://www.openfigi.com/id/BBG000BSWKH7"),
    .init(instrumentID: FinanceIdentity.instrumentID(provider: "openfigi", nativeID: "BBG0015VYNT4"),
      expectedProviderID: "BBG0015VYNT4", expectedSymbol: "VOO", tradingViewSymbol: nil,
      aliases: ["Vanguard S&P 500 ETF"], evidenceURL: "https://www.openfigi.com/id/BBG0015VYNT4"),
    .init(instrumentID: FinanceIdentity.instrumentID(provider: "openfigi", nativeID: "BBG000BVZ4F5"),
      expectedProviderID: "BBG000BVZ4F5", expectedSymbol: "IVV", tradingViewSymbol: nil,
      aliases: ["iShares Core S&P 500 ETF"], evidenceURL: "https://www.openfigi.com/id/BBG000BVZ4F5"),
    .init(instrumentID: FinanceIdentity.instrumentID(provider: "openfigi", nativeID: "BBG000BPH459"),
      expectedProviderID: "BBG000BPH459", expectedSymbol: "MSFT", tradingViewSymbol: nil,
      sectorIDs: ["technology"], aliases: ["Microsoft", "Microsoft Corp"], evidenceURL: "https://www.openfigi.com/id/BBG000BPH459", industryIDs: ["software"]),
    .init(instrumentID: FinanceIdentity.instrumentID(provider: "openfigi", nativeID: "BBG000BVPV84"),
      expectedProviderID: "BBG000BVPV84", expectedSymbol: "AMZN", tradingViewSymbol: nil,
      sectorIDs: ["consumer"], aliases: ["Amazon", "Amazon.com"], evidenceURL: "https://www.openfigi.com/id/BBG000BVPV84", industryIDs: ["retail"]),
    .init(instrumentID: FinanceIdentity.instrumentID(provider: "openfigi", nativeID: "BBG009S39JX6"),
      expectedProviderID: "BBG009S39JX6", expectedSymbol: "GOOGL", tradingViewSymbol: nil,
      sectorIDs: ["technology"], aliases: ["Alphabet", "Google"], evidenceURL: "https://www.openfigi.com/id/BBG009S39JX6", industryIDs: ["software"]),
    .init(instrumentID: FinanceIdentity.instrumentID(provider: "openfigi", nativeID: "BBG000MM2P62"),
      expectedProviderID: "BBG000MM2P62", expectedSymbol: "META", tradingViewSymbol: nil,
      sectorIDs: ["communications"], aliases: ["Meta Platforms", "Facebook"], evidenceURL: "https://www.openfigi.com/id/BBG000MM2P62", industryIDs: ["media"]),
    .init(instrumentID: FinanceIdentity.instrumentID(provider: "openfigi", nativeID: "BBG000CL9VN6"),
      expectedProviderID: "BBG000CL9VN6", expectedSymbol: "NFLX", tradingViewSymbol: nil,
      sectorIDs: ["communications"], aliases: ["Netflix"], evidenceURL: "https://www.openfigi.com/id/BBG000CL9VN6", industryIDs: ["media"]),
    .init(instrumentID: FinanceIdentity.instrumentID(provider: "openfigi", nativeID: "BBG000BBJQV0"),
      expectedProviderID: "BBG000BBJQV0", expectedSymbol: "NVDA", tradingViewSymbol: nil,
      sectorIDs: ["technology"], aliases: ["Nvidia"], evidenceURL: "https://www.openfigi.com/id/BBG000BBJQV0", industryIDs: ["semiconductors"]),
    .init(instrumentID: FinanceIdentity.instrumentID(provider: "openfigi", nativeID: "BBG000N9MNX3"),
      expectedProviderID: "BBG000N9MNX3", expectedSymbol: "TSLA", tradingViewSymbol: nil,
      sectorIDs: ["consumer"], aliases: ["Tesla"], evidenceURL: "https://www.openfigi.com/id/BBG000N9MNX3", industryIDs: ["autos"]),
    .init(instrumentID: FinanceIdentity.instrumentID(provider: "openfigi", nativeID: "BBG000BNBDC2"),
      expectedProviderID: "BBG000BNBDC2", expectedSymbol: "LLY", tradingViewSymbol: nil,
      sectorIDs: ["healthcare"], aliases: ["Eli Lilly", "Lilly"], evidenceURL: "https://www.openfigi.com/id/BBG000BNBDC2", industryIDs: ["pharma"]),
    .init(instrumentID: FinanceIdentity.instrumentID(provider: "openfigi", nativeID: "BBG000BR2B91"),
      expectedProviderID: "BBG000BR2B91", expectedSymbol: "PFE", tradingViewSymbol: nil,
      sectorIDs: ["healthcare"], aliases: ["Pfizer"], evidenceURL: "https://www.openfigi.com/id/BBG000BR2B91", industryIDs: ["pharma"]),
    .init(instrumentID: FinanceIdentity.instrumentID(provider: "openfigi", nativeID: "BBG000B9Y5X2"),
      expectedProviderID: "BBG000B9Y5X2", expectedSymbol: "AAPL", tradingViewSymbol: nil,
      sectorIDs: ["technology"], aliases: ["Apple", "Apple Inc."], evidenceURL: "https://www.openfigi.com/id/BBG000B9Y5X2", industryIDs: ["hardware"]),
    .init(instrumentID: FinanceIdentity.instrumentID(provider: "openfigi", nativeID: "BBG000BCM9N1"),
      expectedProviderID: "BBG000BCM9N1", expectedSymbol: "7203", tradingViewSymbol: nil,
      sectorIDs: ["consumer"], aliases: ["Toyota", "Toyota Motor"], evidenceURL: "https://www.openfigi.com/id/BBG000BCM9N1", industryIDs: ["autos"]),
    .init(instrumentID: FinanceIdentity.instrumentID(provider: "openfigi", nativeID: "BBG000BS1N49"),
      expectedProviderID: "BBG000BS1N49", expectedSymbol: "HSBA", tradingViewSymbol: nil,
      sectorIDs: ["financials"], aliases: ["HSBC", "HSBC Holdings"], evidenceURL: "https://www.openfigi.com/id/BBG000BS1N49", industryIDs: ["banks"])
  ] + FinanceCuratedSecurities.entries

  public static func verifiedInstrumentIDs(domain: String?, account: String?, entries: [Self] = Self.entries) -> [String] {
    entries.filter { entry in !entry.evidenceURL.isEmpty &&
      (domain.map { value in entry.verifiedDomains.contains { $0.lowercased() == value.lowercased() } } == true
        || account.map { entry.verifiedAccounts.contains($0) } == true)
    }.map(\.instrumentID)
  }

  public static func apply(to instrument: FinanceInstrument, entries: [Self] = Self.entries) -> FinanceInstrument {
    guard instrument.isActive else {
      return FinanceInstrument(id: instrument.id, name: instrument.name, symbol: instrument.symbol,
        kind: FinanceReviewedAssets.etfProviderIDs.contains(instrument.providerID) ? "etf" : instrument.kind, providerID: instrument.providerID, exchange: instrument.exchange,
        currency: instrument.currency, mic: instrument.mic,
        shareClassFIGI: instrument.shareClassFIGI, compositeFIGI: instrument.compositeFIGI,
        aliases: instrument.aliases, sectorIDs: instrument.sectorIDs,
        tradingViewSymbol: nil, isActive: false)
    }
    guard let entry = entries.first(where: { $0.instrumentID == instrument.id && $0.expectedProviderID == instrument.providerID
      && $0.expectedSymbol == instrument.symbol && !$0.evidenceURL.isEmpty }),
      entry.sectorIDs.allSatisfy({ id in FinanceSector.all.contains { $0.id == id } }) else { return instrument }
    return FinanceInstrument(id: instrument.id, name: instrument.name, symbol: instrument.symbol,
      kind: FinanceReviewedAssets.etfProviderIDs.contains(instrument.providerID) ? "etf" : instrument.kind, providerID: instrument.providerID, exchange: instrument.exchange, currency: instrument.currency, mic: instrument.mic,
      shareClassFIGI: instrument.shareClassFIGI, compositeFIGI: instrument.compositeFIGI,
      aliases: Set(instrument.aliases + entry.aliases).sorted(), sectorIDs: entry.sectorIDs.isEmpty ? instrument.sectorIDs : entry.sectorIDs,
      tradingViewSymbol: entry.tradingViewSymbol, isActive: instrument.isActive)
  }
}
