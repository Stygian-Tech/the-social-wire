public struct WireDiversityIntervention: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case author
    case domain
    case publication
    case topic
    case community
    case relaxation
  }

  public var canonicalKey: String
  public var kind: Kind

  public init(canonicalKey: String, kind: Kind) {
    self.canonicalKey = canonicalKey
    self.kind = kind
  }
}
