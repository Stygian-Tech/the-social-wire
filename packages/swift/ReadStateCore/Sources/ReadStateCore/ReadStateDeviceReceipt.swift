import Foundation

/// Durable contiguous prefix, not a counter-only authorization to discard pending work.
public struct ReadStateDeviceReceipt: Codable, Sendable, Equatable {
  public let deviceId: String
  public let committedCounter: Int64
  public let prefixHash: String

  public init(viewerDid: String, deviceId: String) throws {
    guard viewerDid.hasPrefix("did:"), viewerDid.utf8.count <= 2048 else { throw ReadStateError.invalidRecord }
    self.deviceId = deviceId
    committedCounter = 0
    prefixHash = try ReadStateV2CanonicalHash.hash(.array([.string("app.thesocialwire.read-state/device/v2"), .string(viewerDid), .string(deviceId)]))
    try validate()
  }
  private init(deviceId: String, counter: Int64, hash: String) { self.deviceId = deviceId; committedCounter = counter; prefixHash = hash }
  private func validate() throws {
    guard UUID(uuidString: deviceId)?.uuidString.lowercased() == deviceId,
      (0...ReadStateValidation.maximumSequence).contains(committedCounter), Self.validHash(prefixHash) else { throw ReadStateError.invalidRecord }
  }
  private static func validHash(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
  public func advancing(firstCounter: Int64, intentHashes: [String]) throws -> Self {
    try validate()
    guard !intentHashes.isEmpty, firstCounter == committedCounter + 1,
      Int64(intentHashes.count) <= ReadStateValidation.maximumSequence - committedCounter else { throw ReadStateError.conflictingSequence }
    var hash = prefixHash
    for (offset, intent) in intentHashes.enumerated() {
      guard Self.validHash(intent) else { throw ReadStateError.invalidRecord }
      hash = try ReadStateV2CanonicalHash.hash(.array([.string("app.thesocialwire.read-state/prefix/v2"), .string(hash), .integer(firstCounter + Int64(offset)), .string(intent)]))
    }
    return Self(deviceId: deviceId, counter: committedCounter + Int64(intentHashes.count), hash: hash)
  }
  /// Returns only the pending prefix proven by its original intent hashes.
  public func verifiedAcknowledgement(_ remote: Self, pendingIntentHashes: [String]) throws -> Int {
    try validate(); try remote.validate()
    let count = remote.committedCounter - committedCounter
    guard deviceId == remote.deviceId, count >= 0, count <= pendingIntentHashes.count else { throw ReadStateError.conflictingSequence }
    let expected = count == 0 ? self : try advancing(firstCounter: committedCounter + 1, intentHashes: Array(pendingIntentHashes.prefix(Int(count))))
    guard expected == remote else { throw ReadStateError.conflictingSequence }
    return Int(count)
  }
}
