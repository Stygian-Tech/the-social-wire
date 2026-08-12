import Foundation

public actor RedisLeaseCoordinator {
  private static let releaseScript = """
  if redis.call('GET', KEYS[1]) == ARGV[1] then
    return redis.call('DEL', KEYS[1])
  end
  return 0
  """

  private static let renewScript = """
  if redis.call('GET', KEYS[1]) == ARGV[1] then
    return redis.call('PEXPIRE', KEYS[1], ARGV[2])
  end
  return 0
  """

  private let commands: any RedisCommandClient
  private let namespace: RedisKeyNamespace
  private let telemetry: RedisTelemetrySink?

  public init(
    commands: any RedisCommandClient,
    namespace: RedisKeyNamespace,
    telemetry: RedisTelemetrySink? = nil
  ) {
    self.commands = commands
    self.namespace = namespace
    self.telemetry = telemetry
  }

  public func acquire(
    domain: String,
    resource: String,
    ttl: TimeInterval
  ) async throws -> RedisLease? {
    let key = namespace.key(domain: "lock", safeComponents: [domain], identifiers: [resource])
    let owner = UUID().uuidString.lowercased()
    let ttlMilliseconds = max(1, Int(ttl * 1_000))
    let acquired = try await commands.setIfAbsent(
      key,
      value: Data(owner.utf8),
      expirationMilliseconds: ttlMilliseconds
    )
    telemetry?(.init(
      kind: .lock,
      operation: domain,
      outcome: acquired ? "acquired" : "contended"
    ))
    return acquired ? RedisLease(key: key, owner: owner, ttlMilliseconds: ttlMilliseconds) : nil
  }

  public func renew(_ lease: RedisLease) async throws -> Bool {
    let result = try await commands.execute(
      command: "EVAL",
      arguments: [
        .data(Data(Self.renewScript.utf8)),
        .integer(1),
        .data(Data(lease.key.utf8)),
        .data(Data(lease.owner.utf8)),
        .integer(lease.ttlMilliseconds),
      ]
    )
    return result == .integer(1)
  }

  public func release(_ lease: RedisLease) async throws -> Bool {
    let result = try await commands.execute(
      command: "EVAL",
      arguments: [
        .data(Data(Self.releaseScript.utf8)),
        .integer(1),
        .data(Data(lease.key.utf8)),
        .data(Data(lease.owner.utf8)),
      ]
    )
    return result == .integer(1)
  }
}
