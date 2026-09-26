import Foundation

/// A reviewable atomic request. References retain their proven CIDs in the local
/// journal; the PDS delete operation itself uses the collection and record key.
public struct ReadStateGarbageCollectionBatch: Codable, Sendable, Equatable {
  public let viewerDid: String
  public let swapCommit: String
  public let previousManifestCid: String
  public let manifest: ReadStateManifest
  public let deletions: [ReadStateReference]

  public func applyWritesJSON() throws -> Data {
    try ReadStateValidation.validate(manifest, viewerDid: viewerDid)
    guard manifest.version == 2, !swapCommit.isEmpty, swapCommit.utf8.count <= 256,
      !previousManifestCid.isEmpty, Set(deletions.map(\.uri)).count == deletions.count else { throw ReadStateError.invalidRecord }
    var writes: [[String: Any]] = [["$type": "com.atproto.repo.applyWrites#update",
      "collection": ReadStateManifest.collection, "rkey": "self",
      "value": try JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest))]]
    let prefix = "at://\(viewerDid)/\(ReadStateChunk.collection)/"
    for reference in deletions {
      try ReadStateValidation.validate(reference, viewerDid: viewerDid)
      writes.append(["$type": "com.atproto.repo.applyWrites#delete", "collection": ReadStateChunk.collection,
        "rkey": String(reference.uri.dropFirst(prefix.count))])
    }
    let data = try JSONSerialization.data(withJSONObject: ["repo": viewerDid, "swapCommit": swapCommit,
      "validate": true, "writes": writes], options: [.sortedKeys, .withoutEscapingSlashes])
    guard !deletions.isEmpty, deletions.count <= 100, data.count <= 256 * 1024 else { throw ReadStateError.sizeLimit }
    return data
  }
}
