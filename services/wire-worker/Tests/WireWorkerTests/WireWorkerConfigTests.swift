import Testing
@testable import WireWorker

@Suite("The Wire worker configuration")
struct WireWorkerConfigTests {
  @Test("defaults to off")
  func offDefault() throws {
    let config = try WireWorkerConfig.load(["DATABASE_URL": "postgres://localhost/wire"])
    #expect(config.mode == .off)
    #expect(config.intervalSeconds == 300)
    #expect(config.generationRetentionSeconds == 172_800)
    #expect(config.baselineLabelers.count == 1)
    #expect(config.baselineLabelers[0].endpointHost == "mod.bsky.app")
    #expect(config.labelRefreshMaximumAgeSeconds == 900)
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
    #expect(throws: WireWorkerConfigError.invalidPositiveInteger("WIRE_CANDIDATE_LIMIT")) {
      try WireWorkerConfig.load(["DATABASE_URL": "postgres://db/wire", "WIRE_CANDIDATE_LIMIT": "0"])
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
  }
}
