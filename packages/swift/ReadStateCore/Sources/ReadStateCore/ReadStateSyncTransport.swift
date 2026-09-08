import Foundation

/// Implementations bind every call to one authenticated viewer and resolved PDS.
public struct ReadStateSyncTransport: Sendable {
  public let readManifest: @Sendable () async throws -> ReadStateManifestRecord?
  public let loadProjection: @Sendable (ReadStateManifest) async throws -> ReadStateProjection
  public let putChunk: @Sendable (String, ReadStateChunk) async throws -> ReadStateReference
  public let putManifest: @Sendable (ReadStateManifest, String?) async throws -> String
  public let confirm: @Sendable (String, Int64?) async throws -> Void

  public init(
    readManifest: @escaping @Sendable () async throws -> ReadStateManifestRecord?,
    loadProjection: @escaping @Sendable (ReadStateManifest) async throws -> ReadStateProjection,
    putChunk: @escaping @Sendable (String, ReadStateChunk) async throws -> ReadStateReference,
    putManifest: @escaping @Sendable (ReadStateManifest, String?) async throws -> String,
    confirm: @escaping @Sendable (String, Int64?) async throws -> Void
  ) {
    self.readManifest = readManifest
    self.loadProjection = loadProjection
    self.putChunk = putChunk
    self.putManifest = putManifest
    self.confirm = confirm
  }
}
