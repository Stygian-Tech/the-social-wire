public struct WireCanonicalIdentity: Codable, Equatable, Sendable {
  public var canonicalKey: String
  public var canonicalURL: String

  public init(canonicalKey: String, canonicalURL: String) {
    self.canonicalKey = canonicalKey
    self.canonicalURL = canonicalURL
  }
}
