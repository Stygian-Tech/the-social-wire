import Foundation
import SocialWireRedis

actor WireRequestLimiter {
  enum Audience: Sendable {
    case anonymous
    case authenticated

    var requestsPerMinute: Double {
      switch self {
      case .anonymous: 60
      case .authenticated: 120
      }
    }

    var burstCapacity: Double {
      switch self {
      case .anonymous: 30
      case .authenticated: 60
      }
    }

    var keyComponent: String {
      switch self {
      case .anonymous: "anonymous"
      case .authenticated: "authenticated"
      }
    }
  }

  private struct Bucket: Sendable {
    var tokens: Double
    var updatedAt: Date
  }

  private var buckets: [String: Bucket] = [:]
  private let redis: (any RedisCommandClient)?
  private let namespace: RedisKeyNamespace

  init(
    redis: (any RedisCommandClient)? = nil,
    environment: String = "local"
  ) {
    self.redis = redis
    self.namespace = RedisKeyNamespace(environment: environment)
  }

  func consume(key: String, audience: Audience, now: Date = Date()) async -> Bool {
    let scopedKey = "\(audience.keyComponent):\(key)"
    if let redis {
      let redisKey = namespace.key(
        domain: "wire-rate-limit",
        safeComponents: [audience.keyComponent],
        identifiers: [key]
      )
      let script = """
        local values=redis.call('HMGET',KEYS[1],'tokens','updated_at')
        local capacity=tonumber(ARGV[3])
        local tokens=tonumber(values[1]) or capacity
        local updated=tonumber(values[2]) or tonumber(ARGV[1])
        local elapsed=math.max(0,tonumber(ARGV[1])-updated)
        tokens=math.min(capacity,tokens+(elapsed*tonumber(ARGV[2])))
        local allowed=0
        if tokens>=1 then tokens=tokens-1 allowed=1 end
        redis.call('HSET',KEYS[1],'tokens',tokens,'updated_at',ARGV[1])
        redis.call('PEXPIRE',KEYS[1],ARGV[4])
        return allowed
        """
      do {
        let value = try await redis.execute(
          command: "EVAL",
          arguments: [
            .data(Data(script.utf8)),
            .integer(1),
            .data(Data(redisKey.utf8)),
            .integer(Int(now.timeIntervalSince1970 * 1_000)),
            .data(Data(String(audience.requestsPerMinute / 60_000).utf8)),
            .integer(Int(audience.burstCapacity)),
            .integer(120_000),
          ]
        )
        if case .integer(let allowed) = value {
          return allowed == 1
        }
      } catch {
        // Redis is disposable acceleration. The per-process bucket remains available.
      }
    }

    var bucket = buckets[scopedKey]
      ?? Bucket(tokens: audience.burstCapacity, updatedAt: now)
    let elapsed = max(0, now.timeIntervalSince(bucket.updatedAt))
    bucket.tokens = min(
      audience.burstCapacity,
      bucket.tokens + elapsed * audience.requestsPerMinute / 60
    )
    bucket.updatedAt = now
    guard bucket.tokens >= 1 else {
      buckets[scopedKey] = bucket
      return false
    }
    bucket.tokens -= 1
    buckets[scopedKey] = bucket
    if buckets.count > 20_000 {
      buckets = buckets.filter { now.timeIntervalSince($0.value.updatedAt) <= 120 }
    }
    return true
  }
}
