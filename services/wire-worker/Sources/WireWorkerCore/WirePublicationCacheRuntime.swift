import Logging
import SocialWireRedis

struct WirePublicationCacheRuntime: Sendable {
  let client: any RedisCommandClient
  let cache: RedisWirePublicationCache
  let telemetry: WirePublicationCacheTelemetry

  static func make(environment: [String: String], logger: Logger) -> Self? {
    guard environment["WIRE_PUBLICATION_CACHE_ENABLED"] == "true",
      let url = environment["REDIS_URL"], !url.isEmpty else { return nil }
    do {
      let configuration = try RedisConfiguration(url: url,
        minimumConnectionCount: 1, maximumConnectionCount: 2,
        commandTimeoutMilliseconds: 100)
      let client = try RediStackRedisClient(configuration: configuration, logger: logger)
      let telemetry = WirePublicationCacheTelemetry()
      return .init(client: client, cache: .init(commands: client,
        namespace: .init(environment: environment["APP_ENV"] ?? "local"), telemetry: telemetry),
        telemetry: telemetry)
    } catch {
      logger.warning("Publication Redis cache unavailable; using Postgres")
      return nil
    }
  }

  func runTelemetry(logger: Logger) async throws {
    while !Task.isCancelled {
      try await Task.sleep(for: .seconds(60))
      await telemetry.emit(logger: logger)
    }
  }

  static func ttl(_ raw: String?, fallback: Double, maximum: Double) -> Double {
    guard let raw, let value = Double(raw), value.isFinite, value > 0 else { return fallback }
    return min(maximum, value)
  }
}
