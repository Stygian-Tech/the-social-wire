import Foundation

/// Durable immutable upload checkpoints. Any base-CID change invalidates all of them.
public struct ReadStateV2Publication: Codable, Sendable {
  public struct Chunk: Codable, Sendable {
    public let key: String
    public var record: ReadStateV2Chunk
    public var reference: ReadStateReference?
  }
  public let baseCid: String
  public let generation: String
  public let revision: Int64
  public let lastSequence: Int64
  public var chunks: [Chunk]
  public var stateHead: ReadStateReference?
  public var devicesHead: ReadStateReference?
  public var legacyReceiptsHead: ReadStateReference?
  public var committedCid: String?
  public var manifest: ReadStateManifest {
    .init(generation: generation, revision: revision, lastSequence: lastSequence,
      stateHead: stateHead, devicesHead: devicesHead, legacyReceiptsHead: legacyReceiptsHead)
  }
}
