import Testing

@testable import WireWorkerCore

@Suite("The Wire worker configuration")
struct WireWorkerConfigTests {
  @Test("defaults to off")
  func offDefault() throws {
    let config = try WireWorkerConfig.load(["DATABASE_URL": "postgres://localhost/wire"])
    #expect(config.mode == .off)
    #expect(config.externalSignalMode == .off)
    #expect(config.role == .combined)
    #expect(config.intervalSeconds == 60)
    #expect(config.generationRetentionSeconds == 172_800)
    #expect(config.baselineLabelers.count == 1)
    #expect(config.baselineLabelers[0].endpointHost == "mod.bsky.app")
    #expect(config.labelRefreshMaximumAgeSeconds == 900)
    #expect(config.inboxBatchSize == 1_000)
    #expect(config.inboxConcurrency == 16)
    #expect(config.inboxIdleMilliseconds == 250)
    #expect(config.inboxCleanupBatchSize == 5_000)
    #expect(config.inboxCleanupIdleMilliseconds == 1_000)
    #expect(config.inboxCleanupEnabled)
    #expect(config.inboxSourceScope == nil)
    #expect(config.metadataBatchSize == 32)
    #expect(config.metadataConcurrency == 8)
    #expect(config.metadataIdleMilliseconds == 1_000)
    #expect(config.postgresMaximumConnections == 12)
  }

  @Test("loads every external-signal rollout mode case insensitively")
  func loadsExternalSignalModes() throws {
    for mode in WireExternalSignalMode.allCases {
      let config = try WireWorkerConfig.load([
        "DATABASE_URL": "postgres://localhost/wire",
        "WIRE_EXTERNAL_SIGNAL_MODE": mode.rawValue.uppercased(),
      ])
      #expect(config.externalSignalMode == mode)
    }
  }

  @Test("loads a normalized inbox source-generation allowlist")
  func loadsInboxSourceScope() throws {
    let config = try WireWorkerConfig.load([
      "DATABASE_URL": "postgres://localhost/wire",
      "APP_ENV": "prod",
      "WIRE_INBOX_SOURCE_GENERATIONS": " wire-global-v4-prod-live-tail-v1,wire-shadow,wire-shadow ",
    ])
    #expect(
      config.inboxSourceScope
        == WireInboxSourceScope(
          environment: "prod",
          sourceGenerations: ["wire-global-v4-prod-live-tail-v1", "wire-shadow"]
        ))
  }

  @Test("loads drain-only role without generation labeler configuration")
  func loadsDrainRole() throws {
    let config = try WireWorkerConfig.load([
      "DATABASE_URL": "postgres://localhost/wire",
      "WIRE_FEED_MODE": "api",
      "WIRE_WORKER_ROLE": "DRAIN",
      "WIRE_ACTOR_HMAC_SECRET": String(repeating: "s", count: 32),
      "WIRE_BASELINE_LABELERS": "ignored-by-drain-role",
    ])
    #expect(config.role == .drain)
    #expect(config.baselineLabelers.isEmpty)
  }

  @Test("loads every worker role case insensitively")
  func loadsRoles() throws {
    for role in WireWorkerRole.allCases {
      let config = try WireWorkerConfig.load([
        "DATABASE_URL": "postgres://localhost/wire",
        "WIRE_WORKER_ROLE": role.rawValue.uppercased(),
      ])
      #expect(config.role == role)
    }
  }

  @Test("explicit host role overrides the legacy environment role")
  func explicitRoleOverride() throws {
    let drainConfig = try WireWorkerConfig.load(
      [
        "DATABASE_URL": "postgres://localhost/wire",
        "WIRE_WORKER_ROLE": "rank",
        "WIRE_BASELINE_LABELERS": "ignored-by-drain-role",
      ],
      role: .drain
    )
    #expect(drainConfig.role == .drain)
    #expect(drainConfig.baselineLabelers.isEmpty)

    let rankConfig = try WireWorkerConfig.load(
      [
        "DATABASE_URL": "postgres://localhost/wire",
        "WIRE_WORKER_ROLE": "drain",
      ],
      role: .rank
    )
    #expect(rankConfig.role == .rank)
    #expect(rankConfig.baselineLabelers.count == 1)
  }

  @Test("loads disabled inbox cleanup")
  func loadsDisabledInboxCleanup() throws {
    let config = try WireWorkerConfig.load([
      "DATABASE_URL": "postgres://localhost/wire",
      "WIRE_INBOX_CLEANUP_ENABLED": "FALSE",
    ])
    #expect(!config.inboxCleanupEnabled)
  }

  @Test("loads every approved rollout mode")
  func loadsModes() throws {
    for mode in WireFeedMode.allCases {
      var environment = [
        "DATABASE_URL": "postgres://localhost/wire", "WIRE_FEED_MODE": mode.rawValue.uppercased(),
      ]
      if mode != .off { environment["WIRE_ACTOR_HMAC_SECRET"] = String(repeating: "s", count: 32) }
      let config = try WireWorkerConfig.load(environment)
      #expect(config.mode == mode)
    }
  }

  @Test("rejects missing database, unknown mode, and invalid integers")
  func rejectsInvalid() {
    #expect(throws: WireWorkerConfigError.missingDatabaseURL) { try WireWorkerConfig.load([:]) }
    #expect(throws: WireWorkerConfigError.invalidMode("loud")) {
      try WireWorkerConfig.load(["DATABASE_URL": "postgres://db/wire", "WIRE_FEED_MODE": "loud"])
    }
    #expect(throws: WireWorkerConfigError.invalidExternalSignalMode("loud")) {
      try WireWorkerConfig.load([
        "DATABASE_URL": "postgres://db/wire", "WIRE_EXTERNAL_SIGNAL_MODE": "loud",
      ])
    }
    #expect(throws: WireWorkerConfigError.invalidRole("loud")) {
      try WireWorkerConfig.load([
        "DATABASE_URL": "postgres://db/wire", "WIRE_WORKER_ROLE": "loud",
      ])
    }
    #expect(throws: WireWorkerConfigError.invalidPositiveInteger("WIRE_CANDIDATE_LIMIT")) {
      try WireWorkerConfig.load(["DATABASE_URL": "postgres://db/wire", "WIRE_CANDIDATE_LIMIT": "0"])
    }
    #expect(throws: WireWorkerConfigError.invalidBoolean("WIRE_INBOX_CLEANUP_ENABLED")) {
      try WireWorkerConfig.load([
        "DATABASE_URL": "postgres://db/wire", "WIRE_INBOX_CLEANUP_ENABLED": "sometimes",
      ])
    }
    #expect(throws: WireWorkerConfigError.missingActorHMACSecret) {
      try WireWorkerConfig.load([
        "DATABASE_URL": "postgres://db/wire", "WIRE_FEED_MODE": "shadow",
      ])
    }
    #expect(throws: WireWorkerConfigError.invalidLabeler("not-a-labeler")) {
      try WireWorkerConfig.load([
        "DATABASE_URL": "postgres://db/wire", "WIRE_BASELINE_LABELERS": "not-a-labeler",
      ])
    }
    #expect(throws: WireWorkerConfigError.invalidLabeler("did:example:test|http://labels.example"))
    {
      try WireWorkerConfig.load([
        "DATABASE_URL": "postgres://db/wire",
        "WIRE_BASELINE_LABELERS": "did:example:test|http://labels.example",
      ])
    }
    #expect(throws: WireWorkerConfigError.invalidPositiveInteger("WIRE_INBOX_CONCURRENCY")) {
      try WireWorkerConfig.load([
        "DATABASE_URL": "postgres://db/wire", "WIRE_INBOX_CONCURRENCY": "65",
      ])
    }
    #expect(throws: WireWorkerConfigError.invalidInboxSourceGenerations) {
      try WireWorkerConfig.load([
        "DATABASE_URL": "postgres://db/wire", "APP_ENV": "prod",
        "WIRE_INBOX_SOURCE_GENERATIONS": "wire-v4,,wire-v5",
      ])
    }
    #expect(throws: WireWorkerConfigError.invalidInboxSourceGenerations) {
      try WireWorkerConfig.load([
        "DATABASE_URL": "postgres://db/wire", "APP_ENV": "prod",
        "WIRE_INBOX_SOURCE_GENERATIONS": "   ",
      ])
    }
    #expect(throws: WireWorkerConfigError.missingInboxEnvironment) {
      try WireWorkerConfig.load([
        "DATABASE_URL": "postgres://db/wire", "WIRE_INBOX_SOURCE_GENERATIONS": "wire-v4",
      ])
    }
    #expect(throws: WireWorkerConfigError.invalidInboxEnvironment("staging")) {
      try WireWorkerConfig.load([
        "DATABASE_URL": "postgres://db/wire", "APP_ENV": "staging",
        "WIRE_INBOX_SOURCE_GENERATIONS": "wire-v4",
      ])
    }
  }
}
