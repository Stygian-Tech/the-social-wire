public struct WireDiversityPolicy: Codable, Equatable, Sendable {
  public var firstPageLimit: Int
  public var maxPerDomain: Int
  public var maxPerPublication: Int
  public var maxPerAuthor: Int
  public var maxPerTopic: Int

  public init(
    firstPageLimit: Int = 50,
    maxPerDomain: Int = 4,
    maxPerPublication: Int = 3,
    maxPerAuthor: Int = 2,
    maxPerTopic: Int = 5,
    maxPerCommunity: Int = 10,
    minimumStrictFill: Int = 40
  ) {
    self.firstPageLimit = firstPageLimit
    self.maxPerDomain = maxPerDomain
    self.maxPerPublication = maxPerPublication
    self.maxPerAuthor = maxPerAuthor
    self.maxPerTopic = maxPerTopic
    self.maxPerCommunity = maxPerCommunity
    self.minimumStrictFill = minimumStrictFill
  }

  var allCaps: [Int] {
    [
      firstPageLimit, maxPerDomain, maxPerPublication, maxPerAuthor, maxPerTopic,
      maxPerCommunity, minimumStrictFill,
    ]
  }

  public var maxPerCommunity: Int
  public var minimumStrictFill: Int
}
