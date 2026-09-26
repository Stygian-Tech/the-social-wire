import Foundation

/// A disposable cache of immutable records already verified against their CID.
/// Rebuilds still traverse and validate the complete referenced generation.
public actor ReadStateVerifiedChunkCache {
  private struct Entry {
    let chunk: ReadStateChunk
    let bytes: Int
    let expiresAt: Date
  }
  private let maximumBytes: Int
  private let maximumEntries: Int
  private let ttl: TimeInterval
  private var entries: [ReadStateReference: Entry] = [:]
  private var bytes = 0

  public init(maximumBytes: Int = 8 * 1024 * 1024, maximumEntries: Int = 512, ttl: TimeInterval = 3600) {
    self.maximumBytes = max(0, maximumBytes)
    self.maximumEntries = max(0, maximumEntries)
    self.ttl = max(0, ttl)
  }

  public func value(for reference: ReadStateReference, now: Date = Date()) -> ReadStateChunk? {
    guard let entry = entries[reference] else { return nil }
    guard entry.expiresAt > now else { remove(reference); return nil }
    return entry.chunk
  }

  /// Call only after the original raw JSON passes ReadStateRecordCID.verify.
  public func insertVerified(_ chunk: ReadStateChunk, for reference: ReadStateReference,
                             now: Date = Date()) throws {
    let size = try ReadStateValidation.encodedByteCount(chunk)
    guard size <= maximumBytes, maximumEntries > 0, ttl > 0 else { return }
    remove(reference)
    for key in entries.keys.filter({ entries[$0]!.expiresAt <= now }) { remove(key) }
    while bytes + size > maximumBytes || entries.count >= maximumEntries {
      guard let oldest = entries.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key else { break }
      remove(oldest)
    }
    entries[reference] = Entry(chunk: chunk, bytes: size, expiresAt: now.addingTimeInterval(ttl))
    bytes += size
  }

  private func remove(_ key: ReadStateReference) {
    if let entry = entries.removeValue(forKey: key) { bytes -= entry.bytes }
  }
}
