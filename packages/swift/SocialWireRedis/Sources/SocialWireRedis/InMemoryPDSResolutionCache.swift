import Foundation

public actor InMemoryPDSResolutionCache: PDSResolutionCache {
  public static let shared = InMemoryPDSResolutionCache()

  private struct Entry: Sendable {
    let endpoint: String?
    let freshUntil: Date
    let hardExpiresAt: Date
  }

  private var entries: [String: Entry] = [:]
  private var leases: [String: RedisLease] = [:]

  public init() {}

  public func lookup(did: String, now: Date) -> PDSResolutionCacheLookup {
    guard let entry = entries[did] else { return .miss }
    guard now < entry.hardExpiresAt else {
      entries.removeValue(forKey: did)
      return .miss
    }
    return now < entry.freshUntil ? .fresh(entry.endpoint) : .stale(entry.endpoint)
  }

  public func storeResolved(did: String, endpoint: String, now: Date) {
    entries[did] = Entry(
      endpoint: endpoint,
      freshUntil: now.addingTimeInterval(30 * 60),
      hardExpiresAt: now.addingTimeInterval(6 * 60 * 60)
    )
  }

  public func storeUnresolved(did: String, now: Date) {
    entries[did] = Entry(
      endpoint: nil,
      freshUntil: now.addingTimeInterval(60),
      hardExpiresAt: now.addingTimeInterval(5 * 60)
    )
  }

  public func acquireLease(did: String, ttl: TimeInterval) -> RedisLease? {
    let now = Date()
    let key = "local:pds-resolution:\(RedisKeyNamespace.digest(did))"
    if let lease = leases[key],
       let expiration = UUIDLeaseExpiration.expiration(for: lease.owner),
       expiration > now
    {
      return nil
    }
    let ttlMilliseconds = max(1, Int(ttl * 1_000))
    let owner = UUIDLeaseExpiration.owner(expiringAt: now.addingTimeInterval(ttl))
    let lease = RedisLease(key: key, owner: owner, ttlMilliseconds: ttlMilliseconds)
    leases[key] = lease
    return lease
  }

  public func releaseLease(_ lease: RedisLease) {
    guard leases[lease.key]?.owner == lease.owner else { return }
    leases.removeValue(forKey: lease.key)
  }
}

private enum UUIDLeaseExpiration {
  static func owner(expiringAt date: Date) -> String {
    "\(date.timeIntervalSince1970):\(UUID().uuidString.lowercased())"
  }

  static func expiration(for owner: String) -> Date? {
    guard let prefix = owner.split(separator: ":", maxSplits: 1).first,
          let interval = TimeInterval(prefix)
    else { return nil }
    return Date(timeIntervalSince1970: interval)
  }
}
