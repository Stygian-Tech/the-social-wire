import Foundation

public struct WireCorpusCandidateRequest: Codable, Equatable, Sendable {
  public static let maximumActorHashesPerRequest = 5_000
  public static let maximumStoriesPerRequest = 500

  public let actorHashes: [String]
  public let language: String
  public let since: Date
  public let limit: Int

  public init(actorHashes: [String], language: String, since: Date, limit: Int) {
    self.actorHashes = actorHashes
    self.language = language
    self.since = since
    self.limit = limit
  }
}
