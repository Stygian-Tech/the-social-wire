import Foundation

public actor RedisCacheClient {
  public enum CacheError: Error, Sendable {
    case circuitOpen
    case malformedValue
  }

  private let commands: any RedisCommandClient
  private let circuitBreaker: RedisCircuitBreaker
  private let telemetry: RedisTelemetrySink?
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  public init(
    commands: any RedisCommandClient,
    circuitBreaker: RedisCircuitBreaker = RedisCircuitBreaker(),
    telemetry: RedisTelemetrySink? = nil
  ) {
    self.commands = commands
    self.circuitBreaker = circuitBreaker
    self.telemetry = telemetry
    self.encoder = JSONEncoder.socialWireRedis
    self.decoder = JSONDecoder.socialWireRedis
  }

  public func lookup<Value: Codable & Sendable>(
    _ type: Value.Type,
    key: String,
    cacheType: String = "generic",
    now: Date = Date()
  ) async throws -> RedisCacheLookup<RedisCacheEnvelope<Value>> {
    do {
      guard await permitted() else { throw CacheError.circuitOpen }
      guard let data = try await commands.get(key) else {
        await recordSuccess()
        telemetry?(.init(kind: .cacheLookup, operation: cacheType, outcome: "miss"))
        return .miss
      }
      let envelope: RedisCacheEnvelope<Value>
      do {
        envelope = try decoder.decode(RedisCacheEnvelope<Value>.self, from: data)
      } catch {
        _ = try? await commands.delete([key])
        await recordSuccess()
        telemetry?(.init(kind: .cacheLookup, operation: cacheType, outcome: "malformed"))
        return .miss
      }
      guard envelope.schemaVersion == RedisCacheEnvelope<Value>.currentSchemaVersion,
            now < envelope.hardExpiresAt
      else {
        _ = try? await commands.delete([key])
        await recordSuccess()
        telemetry?(.init(kind: .cacheLookup, operation: cacheType, outcome: "miss"))
        return .miss
      }
      await recordSuccess()
      if now < envelope.freshUntil {
        telemetry?(.init(kind: .cacheLookup, operation: cacheType, outcome: "fresh_hit"))
        return .fresh(envelope)
      }
      telemetry?(.init(kind: .cacheLookup, operation: cacheType, outcome: "stale_hit"))
      return .stale(envelope)
    } catch {
      if !(error is CacheError) { await recordFailure() }
      if error is CacheError {
        telemetry?(.init(kind: .error, operation: "get", outcome: errorCategory(error)))
      }
      throw error
    }
  }

  public func store<Value: Codable & Sendable>(
    _ value: Value,
    key: String,
    policy: RedisCachePolicy,
    now: Date = Date()
  ) async throws {
    guard await permitted() else {
      telemetry?(.init(kind: .error, operation: "set", outcome: "circuit_open"))
      throw CacheError.circuitOpen
    }
    let jitter = policy.hardDuration * Double.random(in: 0...policy.maximumJitterFraction)
    let envelope = RedisCacheEnvelope(
      value: value,
      cachedAt: now,
      freshUntil: now.addingTimeInterval(policy.freshDuration),
      hardExpiresAt: now.addingTimeInterval(policy.hardDuration + jitter)
    )
    do {
      let data = try encoder.encode(envelope)
      let milliseconds = max(1, Int((policy.hardDuration + jitter) * 1_000))
      try await commands.set(key, value: data, expirationMilliseconds: milliseconds)
      await recordSuccess()
    } catch {
      await recordFailure()
      throw error
    }
  }

  public func delete(_ keys: [String]) async throws {
    guard !keys.isEmpty else { return }
    guard await permitted() else {
      telemetry?(.init(kind: .error, operation: "delete", outcome: "circuit_open"))
      throw CacheError.circuitOpen
    }
    do {
      _ = try await commands.delete(keys)
      await recordSuccess()
    } catch {
      await recordFailure()
      throw error
    }
  }

  private func permitted() async -> Bool {
    let permitted = await circuitBreaker.permit()
    if !permitted {
      let state = await circuitBreaker.state()
      telemetry?(.init(kind: .circuitState, operation: "command", outcome: stateName(state)))
    }
    return permitted
  }

  private func recordSuccess() async {
    await circuitBreaker.recordSuccess()
    telemetry?(.init(kind: .circuitState, operation: "command", outcome: "closed"))
  }

  private func recordFailure() async {
    await circuitBreaker.recordFailure()
    let state = await circuitBreaker.state()
    telemetry?(.init(kind: .circuitState, operation: "command", outcome: stateName(state)))
  }

  private func stateName(_ state: RedisCircuitBreaker.State) -> String {
    switch state {
    case .closed: "closed"
    case .open: "open"
    case .halfOpen: "half_open"
    }
  }

  private func errorCategory(_ error: Error) -> String {
    switch error {
    case CacheError.circuitOpen: "circuit_open"
    case CacheError.malformedValue: "malformed"
    default: "command_failed"
    }
  }

}

extension JSONEncoder {
  fileprivate static var socialWireRedis: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    return encoder
  }
}

extension JSONDecoder {
  fileprivate static var socialWireRedis: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return decoder
  }
}
