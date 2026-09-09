public struct ReadStateLegacyActionReceipt: Codable, Sendable, Equatable {
  public let actionId: String
  public let originalSequence: Int64
  public let originalIntentHash: String
}
