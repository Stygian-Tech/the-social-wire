public struct ReadStateResolution: Sendable, Equatable {
  public let isRead: Bool
  public let readAt: String?
  public let sequence: Int64
  public let actionId: String?
}
