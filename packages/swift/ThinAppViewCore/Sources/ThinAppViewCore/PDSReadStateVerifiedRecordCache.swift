import Foundation
import ReadStateCore

/// One byte budget for immutable v1/v2 records, keyed by the full viewer URI/CID.
public actor PDSReadStateVerifiedRecordCache {
  private struct Entry {
    let json: Data
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

  public func value(for reference: ReadStateReference, now: Date = Date()) -> Data? {
    guard let entry = entries[reference] else { return nil }
    guard entry.expiresAt > now else { remove(reference); return nil }
    return entry.json
  }

  public func insert(_ json: Data, for reference: ReadStateReference, now: Date = Date()) throws {
    guard json.count <= ReadStateValidation.maximumRecordBytes else { throw ReadStateError.sizeLimit }
    try ReadStateRecordCID.verify(json: json, cid: reference.cid)
    guard json.count <= maximumBytes, maximumEntries > 0, ttl > 0 else { return }
    remove(reference)
    for key in entries.keys.filter({ entries[$0]!.expiresAt <= now }) { remove(key) }
    while bytes + json.count > maximumBytes || entries.count >= maximumEntries {
      guard let oldest = entries.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key else { break }
      remove(oldest)
    }
    entries[reference] = Entry(json: json, expiresAt: now.addingTimeInterval(ttl))
    bytes += json.count
  }

  private func remove(_ reference: ReadStateReference) {
    if let entry = entries.removeValue(forKey: reference) { bytes -= entry.json.count }
  }
}
