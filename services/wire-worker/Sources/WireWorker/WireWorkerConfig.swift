import Foundation
import WireCore

struct WireWorkerConfig: Sendable {
  var databaseURL: String
  var mode: WireFeedMode
  var role: WireWorkerRole
  var intervalSeconds: Int
  var candidateLimit: Int
  var generationRetentionSeconds: Int
  var retentionBatchSize: Int
  var languageBucket: String
  var ranking: WireRankingConfig
  var actorHMACSecret: String?
  var baselineLabelers: [WireLabelerEndpoint]
  var labelRefreshMaximumAgeSeconds: Int
  var inboxBatchSize: Int
  var inboxConcurrency: Int
  var inboxIdleMilliseconds: Int
  var inboxCleanupBatchSize: Int
  var inboxCleanupIdleMilliseconds: Int
  var inboxCleanupEnabled: Bool
  var inboxSourceScope: WireInboxSourceScope?
  var metadataBatchSize: Int
  var metadataConcurrency: Int
  var metadataIdleMilliseconds: Int
  var postgresMaximumConnections: Int

  static func load(_ environment: [String: String]) throws -> WireWorkerConfig {
    guard let databaseURL = environment["DATABASE_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !databaseURL.isEmpty
    else {
      throw WireWorkerConfigError.missingDatabaseURL
    }
    let rawMode = environment["WIRE_FEED_MODE"]?.lowercased() ?? WireFeedMode.off.rawValue
    guard let mode = WireFeedMode(rawValue: rawMode) else {
      throw WireWorkerConfigError.invalidMode(rawMode)
    }
    let rawRole = environment["WIRE_WORKER_ROLE"]?.lowercased() ?? WireWorkerRole.combined.rawValue
    guard let role = WireWorkerRole(rawValue: rawRole) else {
      throw WireWorkerConfigError.invalidRole(rawRole)
    }

    let actorHMACSecret = environment["WIRE_ACTOR_HMAC_SECRET"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if mode != .off {
      guard let actorHMACSecret, !actorHMACSecret.isEmpty else {
        throw WireWorkerConfigError.missingActorHMACSecret
      }
      guard actorHMACSecret.utf8.count >= 32 else {
        throw WireWorkerConfigError.invalidActorHMACSecret
      }
    }
    let inboxSourceScope = try inboxSourceScope(environment)

    return WireWorkerConfig(
      databaseURL: databaseURL,
      mode: mode,
      role: role,
      intervalSeconds: try positiveInt(environment, key: "WIRE_RANK_INTERVAL_SECONDS", default: 300),
      candidateLimit: try positiveInt(environment, key: "WIRE_CANDIDATE_LIMIT", default: 5_000),
      generationRetentionSeconds: try positiveInt(
        environment, key: "WIRE_GENERATION_RETENTION_SECONDS", default: 172_800
      ),
      retentionBatchSize: try positiveInt(environment, key: "WIRE_RETENTION_BATCH_SIZE", default: 5_000),
      languageBucket: environment["WIRE_LANGUAGE_BUCKET"]?.lowercased() ?? "und",
      ranking: WireRankingConfig(),
      actorHMACSecret: actorHMACSecret,
      baselineLabelers: role.runsGeneration
        ? try WireLabelerEndpoint.parse(
          environment["WIRE_BASELINE_LABELERS"] ?? WireLabelerEndpoint.blueskyDefault
        ) : [],
      labelRefreshMaximumAgeSeconds: try positiveInt(
        environment, key: "WIRE_LABEL_REFRESH_MAX_AGE_SECONDS", default: 900
      ),
      inboxBatchSize: try boundedPositiveInt(
        environment, key: "WIRE_INBOX_BATCH_SIZE", default: 1_000, maximum: 5_000
      ),
      inboxConcurrency: try boundedPositiveInt(
        environment, key: "WIRE_INBOX_CONCURRENCY", default: 16, maximum: 64
      ),
      inboxIdleMilliseconds: try boundedPositiveInt(
        environment, key: "WIRE_INBOX_IDLE_MILLISECONDS", default: 250, maximum: 60_000
      ),
      inboxCleanupBatchSize: try boundedPositiveInt(
        environment, key: "WIRE_INBOX_CLEANUP_BATCH_SIZE", default: 5_000, maximum: 20_000
      ),
      inboxCleanupIdleMilliseconds: try boundedPositiveInt(
        environment, key: "WIRE_INBOX_CLEANUP_IDLE_MILLISECONDS", default: 1_000, maximum: 60_000
      ),
      inboxCleanupEnabled: try boolean(
        environment, key: "WIRE_INBOX_CLEANUP_ENABLED", default: true
      ),
      inboxSourceScope: inboxSourceScope,
      metadataBatchSize: try boundedPositiveInt(
        environment, key: "WIRE_METADATA_BATCH_SIZE", default: 32, maximum: 250
      ),
      metadataConcurrency: try boundedPositiveInt(
        environment, key: "WIRE_METADATA_CONCURRENCY", default: 8, maximum: 32
      ),
      metadataIdleMilliseconds: try boundedPositiveInt(
        environment, key: "WIRE_METADATA_IDLE_MILLISECONDS", default: 1_000, maximum: 60_000
      ),
      postgresMaximumConnections: try boundedPositiveInt(
        environment, key: "WIRE_POSTGRES_MAX_CONNECTIONS", default: 12, maximum: 64
      )
    )
  }

  private static func inboxSourceScope(
    _ environment: [String: String]
  ) throws -> WireInboxSourceScope? {
    guard let raw = environment["WIRE_INBOX_SOURCE_GENERATIONS"] else { return nil }
    let values = raw.split(separator: ",", omittingEmptySubsequences: false).map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !values.isEmpty, values.allSatisfy({ !$0.isEmpty }) else {
      throw WireWorkerConfigError.invalidInboxSourceGenerations
    }
    var seen = Set<String>()
    let generations = values.filter { seen.insert($0).inserted }
    guard
      let appEnvironment = environment["APP_ENV"]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !appEnvironment.isEmpty
    else { throw WireWorkerConfigError.missingInboxEnvironment }
    guard appEnvironment == "dev" || appEnvironment == "prod" else {
      throw WireWorkerConfigError.invalidInboxEnvironment(appEnvironment)
    }
    return WireInboxSourceScope(
      environment: appEnvironment,
      sourceGenerations: generations
    )
  }

  private static func positiveInt(
    _ environment: [String: String],
    key: String,
    default defaultValue: Int
  ) throws -> Int {
    guard let raw = environment[key] else { return defaultValue }
    guard let value = Int(raw), value > 0 else {
      throw WireWorkerConfigError.invalidPositiveInteger(key)
    }
    return value
  }

  private static func boundedPositiveInt(
    _ environment: [String: String],
    key: String,
    default defaultValue: Int,
    maximum: Int
  ) throws -> Int {
    let value = try positiveInt(environment, key: key, default: defaultValue)
    guard value <= maximum else { throw WireWorkerConfigError.invalidPositiveInteger(key) }
    return value
  }

  private static func boolean(
    _ environment: [String: String],
    key: String,
    default defaultValue: Bool
  ) throws -> Bool {
    guard let raw = environment[key]?.lowercased() else { return defaultValue }
    switch raw {
    case "true": return true
    case "false": return false
    default: throw WireWorkerConfigError.invalidBoolean(key)
    }
  }
}
