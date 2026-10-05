public struct SportsSelection: Codable, Equatable, Sendable {
  public let reference: String
  public let action: String
  public init(reference: String, action: String) { self.reference = reference; self.action = action }
}
