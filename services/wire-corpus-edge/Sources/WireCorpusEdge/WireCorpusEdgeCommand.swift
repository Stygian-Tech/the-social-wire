import ArgumentParser
import Foundation
import Hummingbird
import Logging
import PostgresNIO
import SocialWireRedis

@main
@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct WireCorpusEdgeCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Serve the presentation-safe Production corpus for The Wire"
  )

  @Option(name: .long) var port: Int?
  @Option(name: .long) var hostname: String?

  mutating func run() async throws {
    var logger = Logger(label: "com.thesocialwire.wire-corpus-edge")
    logger.logLevel = .info
    let environment = ProcessInfo.processInfo.environment
    let config = try WireCorpusEdgeConfig.load(environment)
    let postgres = try WireCorpusEdgePostgresConfig.make(
      from: config.databaseURL,
      maximumConnections: config.maximumConnections,
      logger: logger
    )
    let pool = PostgresClient(configuration: postgres, backgroundLogger: logger)
    var redis: RediStackRedisClient?
    var payloadCache: WireCorpusPayloadCache?
    if environment["WIRE_CORPUS_REDIS_CACHE_ENABLED"]?.lowercased() != "false",
      let url = environment["WIRE_CORPUS_REDIS_URL"] ?? environment["REDIS_URL"], !url.isEmpty
    {
      do {
        let client = try RediStackRedisClient(
          configuration: RedisConfiguration(url: url, maximumConnectionCount: 4), logger: logger)
        redis = client
        payloadCache = WireCorpusPayloadCache(
          commands: client, environment: environment["APP_ENV"] ?? "prod", logger: logger)
      } catch {
        logger.warning("Wire public payload cache unavailable; using PostgreSQL")
      }
    }
    let store = PostgresWireCorpusStore(pool: pool, logger: logger, payloadCache: payloadCache)
    let router = WireCorpusEdgeRouterBuilder.router(store: store, config: config, logger: logger)
    let application = Application(
      router: router,
      configuration: .init(
        address: .hostname(
          hostname ?? environment["BIND_HOST"] ?? "::",
          port: port ?? Int(environment["PORT"] ?? "8080") ?? 8080
        )
      )
    )
    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await pool.run() }
        group.addTask { try await application.run() }
        try await group.next()
        group.cancelAll()
      }
    } catch {
      try? await redis?.shutdown()
      throw error
    }
    try? await redis?.shutdown()
  }
}
