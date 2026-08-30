import Foundation

public struct WireCorpusSignalFact: Codable, Equatable, Sendable {
  public let actorHash: String
  public let kind: WireSignalKind
  public let sourceCollection: String
  public let sourceAction: String
  public let sourceURI: String
  public let occurredAt: Date

  public init(
    actorHash: String,
    kind: WireSignalKind,
    sourceCollection: String,
    sourceAction: String,
    sourceURI: String,
    occurredAt: Date
  ) {
    self.actorHash = actorHash
    self.kind = kind
    self.sourceCollection = sourceCollection
    self.sourceAction = sourceAction
    self.sourceURI = sourceURI
    self.occurredAt = occurredAt
  }

  public var isNamedAttributionEligible: Bool {
    switch kind {
    case .recommendation, .share, .quote, .repost:
      true
    case .reply, .like, .publication:
      false
    }
  }
}
