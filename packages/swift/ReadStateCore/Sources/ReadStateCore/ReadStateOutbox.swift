import Foundation

public struct ReadStateOutbox: Codable, Sendable {
  public struct Job: Codable, Sendable {
    public let id: String
    public var operations: [ReadStateOperation]
    public let expectedLegacyRevision: Int64?
    public var replacingManifestCid: String?
    public var publication: Publication?
    public var localOverlay: [ReadStateOperation]? = nil
  }

  public struct Publication: Codable, Sendable {
    public let baseCid: String?
    public let generation: String
    public var chunks: [Chunk]
    public var head: ReadStateReference?
    public let lastSequence: Int64
    public var committedCid: String?
    public var manifestExtensions: [String: ReadStateJSONValue]? = nil
  }

  public struct Chunk: Codable, Sendable {
    public let key: String
    public var record: ReadStateChunk
    public var reference: ReadStateReference?
  }

  public let viewerDid: String
  public var jobs: [Job] = []
  public var retryAfter: Date?
  public var failures = 0

  public init(viewerDid: String) { self.viewerDid = viewerDid }
}
