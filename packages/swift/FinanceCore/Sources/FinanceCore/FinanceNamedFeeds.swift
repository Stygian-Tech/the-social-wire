import Foundation

public enum FinanceNamedFeeds {
  public static let version = "finance-named-feeds-v3"
  /// Verified through OpenFIGI v3 TICKER/US/Equity mapping on 2026-10-02.
  public static let seedFIGIs = FinanceReviewedInstrumentMetadata.entries.map(\.expectedProviderID)
  /// Only explicit stock/fund classifications participate in named-feed menus; reference search stays broader.
  public static func supportsNamedFeed(_ instrument: FinanceInstrument) -> Bool {
    let supported = Set(["common stock", "equity", "stock", "preferred stock", "depositary receipt", "adr", "reit",
      "etf", "mutual fund", "closed-end fund", "closed end fund"])
    return instrument.isActive && supported.contains(instrument.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
  }
  private static func identities(_ figis: [String]) -> [String] {
    figis.map { FinanceIdentity.instrumentID(provider: "openfigi", nativeID: $0) }
  }
  public static func catalog(instruments: [FinanceInstrument]) -> [FinanceFeedDefinition] {
    let active = instruments.filter(supportsNamedFeed)
    let activeIDs = Set(active.map(\.id))
    var feeds = [FinanceFeedDefinition(id: "finance", title: "Finance", kind: "all", description: "Global financial news, personalized to your interests.")]
    feeds += FinanceSector.all.map { sector in FinanceFeedDefinition(id: "industry:" + sector.id, title: sector.name, kind: "industry", instrumentIDs: active.filter { $0.sectorIDs.contains(sector.id) }.map(\.id).sorted(), sectorIDs: [sector.id], description: "Financial reporting about " + sector.name + ".") }
    for industry in FinanceIndustry.all {
      let members = FinanceReviewedInstrumentMetadata.entries.filter { $0.industryIDs.contains(industry.id) }
        .map(\.instrumentID).filter { activeIDs.contains($0) }
      feeds.append(.init(id: "industry:" + industry.id, title: industry.title, kind: "industry", instrumentIDs: members,
        description: "Financial reporting about " + industry.title + "."))
    }
    let groups: [(String, String, [String])] = [
      ("faang", "FAANG", ["BBG000B9Y5X2", "BBG000BVPV84", "BBG009S39JX6", "BBG000MM2P62", "BBG000CL9VN6"]),
      ("mag7", "Mag7", ["BBG000B9Y5X2", "BBG000BPH459", "BBG000BVPV84", "BBG009S39JX6", "BBG000MM2P62", "BBG000BBJQV0", "BBG000N9MNX3"])
    ]
    // A partial group would misleadingly omit a member; publish only fully resolved reviewed identities.
    for (id, title, figis) in groups {
      let members = identities(figis)
      if members.allSatisfy({ activeIDs.contains($0) }) {
        feeds.append(.init(id: "group:" + id, title: title, kind: "group", instrumentIDs: members, description: "Stories associated with the reviewed " + title + " members."))
      }
    }
    feeds += active.sorted { ($0.symbol, $0.exchange ?? "", $0.id) < ($1.symbol, $1.exchange ?? "", $1.id) }.map {
      .init(id: "instrument:" + $0.id, title: "$" + $0.symbol + " · " + $0.name + ($0.exchangeLabel.map { " · " + $0 } ?? ""), kind: "instrument", instrumentIDs: [$0.id], description: "Stories associated with this specific security.")
    }
    return feeds
  }
  public static func revision(instruments: [FinanceInstrument]) -> String {
    let definitions = catalog(instruments: instruments).sorted { $0.id < $1.id }.map {
      $0.id + "|instruments=" + $0.instrumentIDs.sorted().joined(separator: ",")
        + "|sectors=" + $0.sectorIDs.sorted().joined(separator: ",")
    }
    return FinanceIdentity.preferenceFingerprint(instrumentIDs: [version, FinanceReviewedInstrumentMetadata.version,
      FinanceCuratedSecurities.version, FinanceResolver.version] + definitions, sectorIDs: [])
  }
}
