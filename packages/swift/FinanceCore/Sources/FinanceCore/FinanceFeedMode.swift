public enum FinanceFeedMode: String, Codable, Sendable {
  case off, shadow, api, visible
  public init(environmentValue: String?) { self = environmentValue.flatMap(Self.init(rawValue:)) ?? .off }
  public var canServeAPI: Bool { self == .api || self == .visible }
}
