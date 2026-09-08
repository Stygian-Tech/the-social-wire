import Foundation

public enum ReadStateGenerationLoader {
  /// The callback must fetch this exact URI/CID from the viewer's resolved PDS and
  /// verify its content CID. Never implement it by trusting a client-provided body.
  /// Resource exhaustion fails the whole rebuild; it never publishes a partial prefix.
  public static func load(
    manifest: ReadStateManifest, viewerDid: String,
    maximumChunks: Int = 4096, maximumBytes: Int = 16 * 1024 * 1024,
    fetchVerifiedChunk: @Sendable (ReadStateReference) async throws -> ReadStateChunk
  ) async throws -> ReadStateProjection {
    try ReadStateValidation.validate(manifest, viewerDid: viewerDid)
    guard manifest.version == 1 else { throw ReadStateError.invalidRecord }
    var reference = manifest.head
    var visited = Set<ReadStateReference>()
    var operations: [ReadStateOperation] = []
    var bytes = 0
    var allowsRepacking = true
    while let current = reference {
      try Task.checkCancellation()
      guard visited.insert(current).inserted else { throw ReadStateError.invalidReference }
      guard visited.count <= maximumChunks else { throw ReadStateError.sizeLimit }
      let chunk = try await fetchVerifiedChunk(current)
      try ReadStateValidation.validate(chunk, viewerDid: viewerDid)
      let encodedBytes = try ReadStateValidation.encodedByteCount(chunk)
      bytes += chunk.allowsRepacking ? encodedBytes : ReadStateValidation.maximumRecordBytes
      guard bytes <= maximumBytes else { throw ReadStateError.sizeLimit }
      operations.append(contentsOf: chunk.operations)
      allowsRepacking = allowsRepacking && chunk.allowsRepacking
      reference = chunk.previous
    }
    return try ReadStateProjection(operations: operations, lastSequence: manifest.lastSequence,
      sourceChunkCount: visited.count, sourceBytes: bytes, allowsRepacking: allowsRepacking,
      sourceReferences: visited)
  }
}
