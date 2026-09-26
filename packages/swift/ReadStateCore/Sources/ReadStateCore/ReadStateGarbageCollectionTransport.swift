import Foundation

/// Implement only with an audited signed-CAR/commit/MST verifier. An ordinary
/// getRecord response (including 404) is not a membership or absence proof.
/// No native wire implementation is installed by this package.
public struct ReadStateGarbageCollectionTransport: Sendable {
  public struct Snapshot: Sendable {
    public let viewerDid: String
    public let repositoryCommitCid: String
    public let record: ReadStateManifestRecord
    public let projection: ReadStateProjection
    public init(viewerDid: String, repositoryCommitCid: String,
      record: ReadStateManifestRecord, projection: ReadStateProjection) {
      self.viewerDid = viewerDid; self.repositoryCommitCid = repositoryCommitCid
      self.record = record; self.projection = projection
    }
  }
  public struct Page: Sendable {
    public let references: [ReadStateReference]
    public let cursor: String?
    public init(references: [ReadStateReference], cursor: String?) { self.references = references; self.cursor = cursor }
  }
  public struct ChunkProof: Sendable {
    public let viewerDid: String
    public let repositoryCommitCid: String
    public let reference: ReadStateReference
    public let json: Data
    public init(viewerDid: String, repositoryCommitCid: String, reference: ReadStateReference, json: Data) {
      self.viewerDid = viewerDid; self.repositoryCommitCid = repositoryCommitCid
      self.reference = reference; self.json = json
    }
  }
  public struct Commit: Sendable {
    public let repositoryCommitCid: String
    public let manifestCid: String
    public init(repositoryCommitCid: String, manifestCid: String) {
      self.repositoryCommitCid = repositoryCommitCid; self.manifestCid = manifestCid
    }
  }
  /// Bind signed repo DID, commit CID and MST path app.thesocialwire.readState/self
  /// to record.cid, then CID-verify and load every referenced state/control chunk.
  public let verifiedSnapshot: @Sendable () async throws -> Snapshot?
  /// Server authority/readiness confirmation is required before planning and after collection.
  public let confirmGeneration: @Sendable (String) async throws -> Void
  public let listChunks: @Sendable (String?, Int) async throws -> Page
  /// The proof must bind this exact URI and CID to the requested repo commit.
  /// Nil skips the candidate; it is never taken as evidence of deletion.
  public let verifiedChunk: @Sendable (ReadStateReference, String) async throws -> ChunkProof?
  /// One applyWrites transaction: swapCommit + singleton update + all deletes.
  /// Implementations must not substitute individual deleteRecord calls.
  public let applyAtomic: @Sendable (ReadStateGarbageCollectionBatch) async throws -> Commit
  public init(verifiedSnapshot: @escaping @Sendable () async throws -> Snapshot?,
    confirmGeneration: @escaping @Sendable (String) async throws -> Void,
    listChunks: @escaping @Sendable (String?, Int) async throws -> Page,
    verifiedChunk: @escaping @Sendable (ReadStateReference, String) async throws -> ChunkProof?,
    applyAtomic: @escaping @Sendable (ReadStateGarbageCollectionBatch) async throws -> Commit) {
    self.verifiedSnapshot = verifiedSnapshot; self.confirmGeneration = confirmGeneration; self.listChunks = listChunks
    self.verifiedChunk = verifiedChunk; self.applyAtomic = applyAtomic
  }
}
