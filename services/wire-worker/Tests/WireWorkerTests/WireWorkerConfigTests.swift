import Testing
@testable import WireWorker

@Suite("The Wire worker configuration")
struct WireWorkerConfigTests {
  @Test("defaults to off")
  func offDefault() throws {
    let config = try WireWorkerConfig.load(["DATABASE_URL": "postgres://localhost/wire"])
    #expect(config.mode == .off)
    #expect(config.role == .combined)
    #expect(config.intervalSeconds == 300)
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
    #expect(config.postgresMaximumConnections == 12)
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
    #expect(throws: WireWorkerConfigError.invalidLabeler("did:example:test|http://labels.example")) {
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
  }
}
