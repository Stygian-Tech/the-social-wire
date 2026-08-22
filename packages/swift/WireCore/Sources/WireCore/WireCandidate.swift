import Foundation

public struct WireCandidate: Codable, Equatable, Sendable {
  public var canonicalKey: String
  public var canonicalURL: String
  public var representativeURI: String?
  public var sourceDomain: String
  public var publicationID: String?
  public var authorKey: String?
  public var topicKeys: [String]
  public var publishedAt: Date?
  public var firstSeenAt: Date
  public var lastSignalAt: Date?
  public var distinctActors1h: Int
  public var distinctActors24h: Int
  public var distinctActors7d: Int
  public var signals1h: Int
  public var signals24h: Int
  public var signals7d: Int
  public var communities24h: Int
  public var primaryCommunityKey: String?
  public var recommendations24h: Int
  public var shares1h: Int
  public var shares24h: Int
  public var distinctLikes24h: Int
  public var likes1h: Int
  public var likes24h: Int
  public var distinctReposts24h: Int
  public var reposts1h: Int
  public var reposts24h: Int
  public var sourceConfidence: Double
  public var isStandardSite: Bool?
  public var hasUsableOpenGraphMetadata: Bool?

  public init(
    canonicalKey: String,
    canonicalURL: String,
    representativeURI: String?,
    sourceDomain: String,
    publicationID: String? = nil,
    authorKey: String? = nil,
    topicKeys: [String] = [],
    publishedAt: Date? = nil,
    firstSeenAt: Date,
    lastSignalAt: Date? = nil,
    distinctActors1h: Int = 0,
    distinctActors24h: Int = 0,
    distinctActors7d: Int = 0,
    signals1h: Int = 0,
    signals24h: Int = 0,
    signals7d: Int = 0,
    communities24h: Int = 0,
    primaryCommunityKey: String? = nil,
    recommendations24h: Int = 0,
    shares1h: Int? = nil,
    shares24h: Int? = nil,
    distinctLikes24h: Int = 0,
    likes1h: Int = 0,
    likes24h: Int = 0,
    distinctReposts24h: Int = 0,
    reposts1h: Int = 0,
    reposts24h: Int = 0,
    sourceConfidence: Double = 0.5,
    isStandardSite: Bool = false,
    hasUsableOpenGraphMetadata: Bool = false
  ) {
    self.canonicalKey = canonicalKey
    self.canonicalURL = canonicalURL
    self.representativeURI = representativeURI
    self.sourceDomain = sourceDomain
    self.publicationID = publicationID
    self.authorKey = authorKey
    self.topicKeys = topicKeys
    self.publishedAt = publishedAt
    self.firstSeenAt = firstSeenAt
    self.lastSignalAt = lastSignalAt
    self.distinctActors1h = distinctActors1h
    self.distinctActors24h = distinctActors24h
    self.distinctActors7d = distinctActors7d
    self.signals1h = signals1h
    self.signals24h = signals24h
    self.signals7d = signals7d
    self.communities24h = communities24h
    self.primaryCommunityKey = primaryCommunityKey
    self.recommendations24h = recommendations24h
    self.shares1h = shares1h ?? signals1h
    self.shares24h = shares24h ?? signals24h
    self.distinctLikes24h = distinctLikes24h
    self.likes1h = likes1h
    self.likes24h = likes24h
    self.distinctReposts24h = distinctReposts24h
    self.reposts1h = reposts1h
    self.reposts24h = reposts24h
    self.sourceConfidence = sourceConfidence
    self.isStandardSite = isStandardSite
    self.hasUsableOpenGraphMetadata = hasUsableOpenGraphMetadata
  }
}
