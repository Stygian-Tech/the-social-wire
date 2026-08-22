import Foundation

/// Privacy-safe aggregate input for edition assembly. The counts participate in
/// deterministic selection but are deliberately not part of a Codable public response.
public struct WireTalkedAboutAccountCandidate: Equatable, Sendable {
  public let account: WireTalkedAboutAccount
  public let distinctStoryCount: Int
  public let distinctSpeakerCount: Int
  public let bestStoryRank: Int
  public let latestMentionAt: Date?

  public init(
    account: WireTalkedAboutAccount,
    distinctStoryCount: Int,
    distinctSpeakerCount: Int,
    bestStoryRank: Int,
    latestMentionAt: Date?
  ) {
    self.account = account
    self.distinctStoryCount = max(0, distinctStoryCount)
    self.distinctSpeakerCount = max(0, distinctSpeakerCount)
    self.bestStoryRank = max(0, bestStoryRank)
    self.latestMentionAt = latestMentionAt
  }
}
