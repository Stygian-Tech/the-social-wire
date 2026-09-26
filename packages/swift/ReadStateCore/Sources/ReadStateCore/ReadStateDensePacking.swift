import Foundation

/// Lossless packing preserves every action ID and committed sequence, including
/// actions superseded by later operations so unknown-success retries stay safe.
public enum ReadStateDensePacking {
  public static func chunks(operations: [ReadStateOperation], viewerDid: String) throws -> [ReadStateChunk] {
    let reference = placeholder(viewerDid: viewerDid)
    var result: [ReadStateChunk] = []
    var buffer: [ReadStateOperation] = []
    for operation in operations {
      try ReadStateValidation.validate(operation)
      let candidate = ReadStateChunk(operations: buffer + [operation], previous: reference)
      let size = try ReadStateValidation.encodedByteCount(candidate)
      if buffer.count >= 128 || size > ReadStateValidation.maximumRecordBytes {
        guard !buffer.isEmpty else { throw ReadStateError.sizeLimit }
        result.append(.init(operations: buffer, previous: nil))
        buffer = []
      }
      try ReadStateValidation.validateSize(ReadStateChunk(operations: [operation], previous: reference))
      buffer.append(operation)
    }
    if !buffer.isEmpty { result.append(.init(operations: buffer, previous: nil)) }
    return result
  }

  /// Conservative upper bound reserves maximum URI/CID space before any upload.
  public static func validateGeneration(chunks: [ReadStateChunk], viewerDid: String,
      existingChunkCount: Int = 0, existingBytes: Int = 0) throws {
    guard existingChunkCount + chunks.count <= 4096 else { throw ReadStateError.sizeLimit }
    var bytes = existingBytes
    for chunk in chunks {
      bytes += try ReadStateValidation.encodedByteCount(ReadStateChunk(operations: chunk.operations,
        previous: placeholder(viewerDid: viewerDid)))
      guard bytes <= 16 * 1024 * 1024 else { throw ReadStateError.sizeLimit }
    }
  }

  private static func placeholder(viewerDid: String) -> ReadStateReference {
    .init(uri: "at://\(viewerDid)/\(ReadStateChunk.collection)/" + String(repeating: "a", count: 512),
      cid: String(repeating: "b", count: 256))
  }
}
