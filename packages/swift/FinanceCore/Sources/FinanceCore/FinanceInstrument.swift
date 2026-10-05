import Foundation

public struct FinanceInstrument: Codable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let symbol: String
  public let kind: String
  public let providerID: String
  public let exchange: String?
  public let mic: String?
  public let shareClassFIGI: String?
  public let compositeFIGI: String?
  public let currency: String?
  public let aliases: [String]
  public let sectorIDs: [String]
  public let tradingViewSymbol: String?
  public let isActive: Bool

  /// Presentation metadata comes from the reviewed reference catalog, never from a widget.
  public var exchangeName: String? { FinanceExchangeDisplay.name(for: self) }
  public var exchangeLabel: String? {
    guard let exchange, !exchange.isEmpty else { return exchangeName }
    return exchangeName.map { $0 + " (" + exchange + ")" } ?? "Exchange: " + exchange
  }

  private enum EncodingKeys: String, CodingKey {
    case id, name, symbol, kind, providerID, exchange, exchangeName, mic, shareClassFIGI, compositeFIGI
    case currency, aliases, sectorIDs, tradingViewSymbol, isActive
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: EncodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(symbol, forKey: .symbol)
    try container.encode(kind, forKey: .kind)
    try container.encode(providerID, forKey: .providerID)
    try container.encodeIfPresent(exchange, forKey: .exchange)
    try container.encodeIfPresent(exchangeName, forKey: .exchangeName)
    try container.encodeIfPresent(mic, forKey: .mic)
    try container.encodeIfPresent(shareClassFIGI, forKey: .shareClassFIGI)
    try container.encodeIfPresent(compositeFIGI, forKey: .compositeFIGI)
    try container.encodeIfPresent(currency, forKey: .currency)
    try container.encode(aliases, forKey: .aliases)
    try container.encode(sectorIDs, forKey: .sectorIDs)
    try container.encodeIfPresent(tradingViewSymbol, forKey: .tradingViewSymbol)
    try container.encode(isActive, forKey: .isActive)
  }

  public init(id: String, name: String, symbol: String, kind: String, providerID: String,
    exchange: String? = nil, currency: String? = nil, mic: String? = nil, shareClassFIGI: String? = nil, compositeFIGI: String? = nil, aliases: [String] = [],
    sectorIDs: [String] = [], tradingViewSymbol: String? = nil, isActive: Bool = true) {
    self.id = id; self.name = name; self.symbol = symbol; self.kind = kind
    self.providerID = providerID; self.exchange = exchange; self.currency = currency; self.mic = mic; self.shareClassFIGI = shareClassFIGI; self.compositeFIGI = compositeFIGI
    self.aliases = aliases; self.sectorIDs = sectorIDs
    self.tradingViewSymbol = tradingViewSymbol; self.isActive = isActive
  }
}
