import Foundation
import SocialWireRedis

/// A bounded read-through cache. Epochs prevent an old database/PDS read from
/// repopulating a key after a different worker invalidates it.
struct RedisWirePublicationCache: WirePublicationCaching {
  let commands: any RedisCommandClient
  let namespace: RedisKeyNamespace
  let telemetry: WirePublicationCacheTelemetry?

  init(commands: any RedisCommandClient, namespace: RedisKeyNamespace,
    telemetry: WirePublicationCacheTelemetry? = nil)
  {
    self.commands = commands
    self.namespace = namespace
    self.telemetry = telemetry
  }

  func lookup(_ uri: String, asOf: Date) async throws -> WirePublicationCacheLookup {
    let result: RedisCommandValue
    do {
      result = try await evaluate(Self.lookupScript, uri: uri, arguments: [
        .data(Data(UUID().uuidString.utf8))
      ])
    } catch {
      await telemetry?.record(.unavailable)
      throw error
    }
    guard case .array(let parts) = result, parts.count == 2, let token = parts[0].string else {
      await telemetry?.record(.unavailable)
      throw CacheError.invalidResponse
    }
    let value: WirePublicationCacheValue?
    if case .data(let data) = parts[1], data.count <= 16_384,
      let decoded = try? JSONDecoder().decode(WirePublicationCacheValue.self, from: data),
      decoded.expiresAt > asOf,
      decoded.metadata == nil || decoded.metadata?.publicationURI == uri
    {
      value = decoded
    } else {
      value = nil
    }
    await telemetry?.record(value == nil ? .miss : .hit)
    return .init(token: token, value: value)
  }

  func fill(_ uri: String, token: String, value: WirePublicationCacheValue, asOf: Date) async throws {
    let duration = min(60, value.expiresAt.timeIntervalSince(asOf))
    guard duration > 0 else { return }
    let data = try JSONEncoder().encode(value)
    guard data.count <= 16_384 else { return }
    _ = try await evaluate(Self.fillScript, uri: uri, arguments: [
      .data(Data(token.utf8)), .data(data), .integer(max(1, Int(duration * 1_000)))
    ])
  }

  func invalidate(_ uri: String) async throws {
    _ = try await evaluate(Self.invalidateScript, uri: uri, arguments: [
      .data(Data(UUID().uuidString.utf8))
    ])
  }

  func invalidateAccount(_ repoDID: String) async throws {
    let key = namespace.key(domain: "wire-publication-epoch", identifiers: [repoDID])
    try await commands.set(key, value: Data(UUID().uuidString.utf8), expirationMilliseconds: 120_000)
  }

  private func evaluate(_ script: String, uri: String, arguments: [RedisCommandValue]) async throws -> RedisCommandValue {
    guard let reference = WirePublicationReference.parse(uri) else { throw CacheError.invalidResponse }
    let key = namespace.key(domain: "wire-publication", identifiers: [uri])
    let epoch = namespace.key(domain: "wire-publication-epoch", identifiers: [reference.repoDID])
    return try await commands.execute(command: "EVAL", arguments: [
      .data(Data(script.utf8)), .integer(2),
      .data(Data(epoch.utf8)), .data(Data("\(key):value".utf8))
    ] + arguments)
  }

  private enum CacheError: Error { case invalidResponse }

  static let lookupScript = """
    local epoch = redis.call('GET', KEYS[1])
    if not epoch then
      epoch = ARGV[1]
      redis.call('SET', KEYS[1], epoch, 'EX', 120)
      redis.call('DEL', KEYS[2])
    end
    local value = redis.call('GET', KEYS[2])
    if not value or string.sub(value, 1, string.len(epoch) + 1) ~= epoch .. ':' then
      return {epoch, false}
    end
    return {epoch, string.sub(value, string.len(epoch) + 2)}
    """
  static let fillScript = """
    if redis.call('GET', KEYS[1]) ~= ARGV[1] then return 0 end
    redis.call('SET', KEYS[2], ARGV[1] .. ':' .. ARGV[2], 'PX', ARGV[3])
    return 1
    """
  static let invalidateScript = """
    redis.call('SET', KEYS[1], ARGV[1], 'EX', 120)
    redis.call('DEL', KEYS[2])
    return 1
    """
}
