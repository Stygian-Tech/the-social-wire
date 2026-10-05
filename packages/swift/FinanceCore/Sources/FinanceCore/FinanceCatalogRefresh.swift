import Foundation

public enum FinanceCatalogRefresh {
  /// Construct the full candidate before the caller activates it in one database transaction.
  /// A failure throws without replacing the previous active snapshot.
  public static func candidate(previous: FinanceCatalogSnapshot?, securities: [FinanceInstrument],
    crypto: [FinanceInstrument], reviewed: [FinanceInstrument] = FinanceReviewedCatalog.instruments,
    now: Date = Date()) throws -> FinanceCatalogSnapshot {
    let all = securities + crypto + reviewed
    guard !all.isEmpty, Set(all.map(\.id)).count == all.count,
      all.allSatisfy({ !$0.id.isEmpty && !$0.providerID.isEmpty && !$0.symbol.isEmpty })
    else { throw FinanceProviderError.invalidResponse }
    let previousByID = Dictionary(uniqueKeysWithValues: (previous?.instruments ?? []).map { ($0.id, $0) })
    let merged = all.map { instrument in
      guard let old = previousByID[instrument.id] else { return instrument }
      return FinanceInstrument(id: instrument.id, name: instrument.name, symbol: instrument.symbol,
        kind: instrument.kind, providerID: instrument.providerID, exchange: instrument.exchange,
        currency: instrument.currency ?? old.currency, mic: instrument.mic ?? old.mic,
        shareClassFIGI: instrument.shareClassFIGI ?? old.shareClassFIGI, compositeFIGI: instrument.compositeFIGI ?? old.compositeFIGI,
        aliases: Set(instrument.aliases + old.aliases + (old.symbol == instrument.symbol ? [] : [old.symbol])).sorted(),
        sectorIDs: instrument.sectorIDs.isEmpty ? old.sectorIDs : instrument.sectorIDs,
        tradingViewSymbol: old.symbol == instrument.symbol ? old.tradingViewSymbol : nil,
        isActive: instrument.isActive)
    }
    let present = Set(merged.map(\.id))
    let inactive = (previous?.instruments ?? []).filter { !present.contains($0.id) }.map {
      FinanceInstrument(id: $0.id, name: $0.name, symbol: $0.symbol, kind: $0.kind,
        providerID: $0.providerID, exchange: $0.exchange, currency: $0.currency, mic: $0.mic, shareClassFIGI: $0.shareClassFIGI, compositeFIGI: $0.compositeFIGI,
        aliases: $0.aliases, sectorIDs: $0.sectorIDs, tradingViewSymbol: nil, isActive: false)
    }
    return .init(version: UUID().uuidString, generatedAt: now,
      instruments: (merged + inactive).map { FinanceReviewedInstrumentMetadata.apply(to: $0) }.sorted { $0.id < $1.id })
  }
}
