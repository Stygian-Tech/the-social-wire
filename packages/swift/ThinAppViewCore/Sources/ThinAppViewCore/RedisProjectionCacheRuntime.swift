import Foundation
import Logging
import SocialWireRedis

public struct RedisProjectionCacheRuntime: Sendable {
  public let store: any AppViewProjectionCacheStore
  public let resolutionCache: any PDSResolutionCache
  /// Shared connection pool for service-owned disposable caches. Runtime owns shutdown.
  public let client: any RedisCommandClient
  private let infoSampler: RedisInfoSampler

  public static func make(
    environment: [String: String],
    appEnvironment: String,
    logger: Logger,
    telemetry: RedisTelemetrySink? = nil
  ) -> RedisProjectionCacheRuntime? {
    guard let url = environment["REDIS_URL"], !url.isEmpty else {
      logger.error("Redis cache backend selected without REDIS_URL; continuing without cache")
      return nil
    }
    do {
      let configuration = try RedisConfiguration(
        url: url,
        minimumConnectionCount: positiveInt(environment["REDIS_POOL_MIN"], fallback: 1),
        maximumConnectionCount: positiveInt(environment["REDIS_POOL_MAX"], fallback: 8),
        commandTimeoutMilliseconds: positiveInt(
          environment["REDIS_COMMAND_TIMEOUT_MILLISECONDS"],
          fallback: 250
        )
      )
      let client = try RediStackRedisClient(
        configuration: configuration,
        logger: logger,
        telemetry: telemetry
      )
      let store = RedisAppViewProjectionCacheStore(
        commands: client,
        environment: appEnvironment,
        logger: logger,
        telemetry: telemetry,
        sidebarPolicy: RedisCachePolicy(
          freshDuration: positiveSeconds(
            environment["APPVIEW_SIDEBAR_CACHE_FRESH_SECONDS"],
            fallback: AppViewProjectionCacheTTL.sidebarSeconds
          ),
          hardDuration: positiveSeconds(
            environment["APPVIEW_SIDEBAR_CACHE_HARD_SECONDS"],
            fallback: AppViewProjectionCacheTTL.sidebarHardSeconds
          )
        ),
        unreadPolicy: RedisCachePolicy(
          freshDuration: positiveSeconds(
            environment["APPVIEW_UNREAD_CACHE_FRESH_SECONDS"],
            fallback: AppViewProjectionCacheTTL.unreadCountsSeconds
          ),
          hardDuration: positiveSeconds(
            environment["APPVIEW_UNREAD_CACHE_HARD_SECONDS"],
            fallback: AppViewProjectionCacheTTL.unreadCountsHardSeconds
          )
        ),
        firstPagePolicy: RedisCachePolicy(
          freshDuration: positiveSeconds(
            environment["APPVIEW_FIRST_PAGE_CACHE_FRESH_SECONDS"],
            fallback: AppViewProjectionCacheTTL.firstPageSeconds
          ),
          hardDuration: positiveSeconds(
            environment["APPVIEW_FIRST_PAGE_CACHE_HARD_SECONDS"],
            fallback: AppViewProjectionCacheTTL.firstPageHardSeconds
          )
        )
      )
      return RedisProjectionCacheRuntime(
        store: store,
        resolutionCache: RedisPDSResolutionCache(
          commands: client,
          environment: appEnvironment,
          telemetry: telemetry
        ),
        infoSampler: RedisInfoSampler(commands: client, telemetry: telemetry),
        client: client
      )
    } catch {
      logger.error("Redis cache initialization failed; continuing without cache", metadata: [
        "error_category": .string("configuration_or_connection")
      ])
      return nil
    }
  }

  public func shutdown() async {
    await PDSResolutionCacheRegistry.shared.install(nil)
    try? await client.shutdown()
  }

  public func installResolutionCache() async {
    await PDSResolutionCacheRegistry.shared.install(resolutionCache)
  }

  public func runInfoSampling() async {
    await infoSampler.runForever()
  }

  private init(
    store: any AppViewProjectionCacheStore,
    resolutionCache: any PDSResolutionCache,
    infoSampler: RedisInfoSampler,
    client: any RedisCommandClient
  ) {
    self.store = store
    self.resolutionCache = resolutionCache
    self.infoSampler = infoSampler
    self.client = client
  }

  private static func positiveInt(_ raw: String?, fallback: Int) -> Int {
    guard let raw, let value = Int(raw), value > 0 else { return fallback }
    return value
  }

  private static func positiveSeconds(_ raw: String?, fallback: TimeInterval) -> TimeInterval {
    guard let raw, let value = TimeInterval(raw), value > 0 else { return fallback }
    return value
  }
}
