import Foundation
import SocialWireRedis
import Testing
@testable import WireCorpusEdge

@Suite("Authoritative public corpus payload cache")
struct WireCorpusPayloadCacheTests {
  actor Source {
    var revision = "first"
    var payload = "original"
    var loads = 0
    func change(_ revision: String, _ payload: String) {
      self.revision = revision
      self.payload = payload
    }
    func current() -> String { revision }
    func load() -> String { loads += 1; return payload }
  }
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  private func read(_ cache: WireCorpusPayloadCache, _ source: Source, at: Date,
    scope: [String] = ["feed", "generation", "en", "0", "10"]
  ) async throws -> String {
    try await cache.value(String.self, scope: scope, revision: source.current(), now: at,
      currentRevision: { await source.current() }, load: { await source.load() })
  }

  @Test("cold miss, shared hit, hard expiry and flush rebuild")
  func lifecycle() async throws {
    let commands = CorpusCacheCommands()
    let cache = WireCorpusPayloadCache(commands: commands, environment: "prod")
    let source = Source()
    #expect(try await read(cache, source, at: now) == "original")
    #expect(try await read(cache, source, at: now.addingTimeInterval(59)) == "original")
    #expect(await source.loads == 1)
    #expect(await cache.statistics()["feed_hit"] == 1)
    #expect(await cache.statistics()["feed_miss"] == 1)
    #expect(try await read(cache, source, at: now.addingTimeInterval(599)) == "original")
    #expect(await source.loads == 1)
    #expect(try await read(cache, source, at: now.addingTimeInterval(600)) == "original")
    #expect(await source.loads == 2)
    await commands.flush()
    _ = try await read(cache, source, at: now.addingTimeInterval(601))
    #expect(await source.loads == 3)
    #expect(await commands.expirations.allSatisfy { $0 == 600_000 })
  }

  @Test("moderation deletion, resurrection and payload updates invalidate by authoritative revision")
  func authorityChanges() async throws {
    let commands = CorpusCacheCommands()
    let cache = WireCorpusPayloadCache(commands: commands, environment: "prod")
    let source = Source()
    _ = try await read(cache, source, at: now)
    await source.change("empty-membership", "empty")
    let later = now.addingTimeInterval(120)
    #expect(try await read(cache, source, at: later) == "empty")
    await source.change("restored-row-version", "restored")
    #expect(try await read(cache, source, at: later) == "restored")
    await source.change("edited-row-version", "edited")
    #expect(try await read(cache, source, at: later) == "edited")
    #expect(await source.loads == 4)
  }

  @Test("generation retention caps Redis TTL and expired generations cannot fill it")
  func generationExpiryCap() async throws {
    let commands = CorpusCacheCommands()
    let cache = WireCorpusPayloadCache(commands: commands, environment: "prod")
    let expiry = now.addingTimeInterval(90)
    let lifetime = WireCorpusPayloadCache.generationLifetime(expiresAt: expiry, now: now)
    _ = try await cache.value(String.self, scope: ["feed", "short"], revision: "first", now: now,
      lifetime: lifetime, currentRevision: { "first" }, load: { "payload" })
    #expect(await commands.expirations == [90_000])
    for at in [expiry, expiry.addingTimeInterval(1)] {
      let remaining = WireCorpusPayloadCache.generationLifetime(expiresAt: expiry, now: at)
      #expect(remaining == 0)
      _ = try await cache.value(String.self, scope: ["feed", "expired"], revision: "first", now: at,
        lifetime: remaining, currentRevision: { "first" }, load: { "payload" })
    }
    #expect(await commands.writes == 1)
    #expect(WireCorpusPayloadCache.generationLifetime(
      expiresAt: now.addingTimeInterval(7200), now: now) == 600)
  }

  @Test("failed Redis and oversized results use the authoritative source")
  func unavailableAndSizeLimit() async throws {
    let commands = CorpusCacheCommands()
    let cache = WireCorpusPayloadCache(commands: commands, environment: "prod", maximumPayloadBytes: 2)
    let source = Source()
    _ = try await read(cache, source, at: now)
    _ = try await read(cache, source, at: now)
    #expect(await commands.writes == 0)
    await commands.fail(true)
    #expect(try await read(cache, source, at: now) == "original")
    #expect(await source.loads == 3)
    #expect(await cache.statistics()["feed_redis_error"] == 1)
  }

  @Test("keys isolate environment, generation, region, language and page size")
  func scopeIsolation() async throws {
    let commands = CorpusCacheCommands()
    let prod = WireCorpusPayloadCache(commands: commands, environment: "prod")
    let dev = WireCorpusPayloadCache(commands: commands, environment: "dev")
    let source = Source()
    for scope in [
      ["edition", "generation-a", "en", "us"], ["edition", "generation-a", "en", "outside_us"],
      ["edition", "generation-a", "zh", "us"], ["edition", "generation-b", "en", "us"],
      ["feed", "generation-a", "0", "10"], ["feed", "generation-a", "0", "20"],
      ["item", "https://private-looking.example/item"]
    ] { _ = try await read(prod, source, at: now, scope: scope) }
    _ = try await read(dev, source, at: now, scope: ["edition", "generation-a", "en", "us"])
    #expect(await source.loads == 8)
    #expect(await commands.keys().allSatisfy { !$0.contains("private-looking") })
  }

  @Test("a source change during fill never stores a mismatched payload")
  func concurrentFill() async throws {
    let commands = CorpusCacheCommands()
    let cache = WireCorpusPayloadCache(commands: commands, environment: "prod")
    let source = Source()
    let value = try await cache.value(String.self, scope: ["item", "one"], revision: "first", now: now,
      currentRevision: { await source.current() }, load: {
        await source.change("second", "changed")
        return await source.load()
      })
    #expect(value == "changed")
    #expect(await commands.writes == 0)
  }

  @Test("temporary membership changes cannot poison a stable empty revision")
  func membershipABA() async throws {
    let commands = CorpusCacheCommands()
    let cache = WireCorpusPayloadCache(commands: commands, environment: "prod")
    // A label can be removed and restored during a multi-query miss: both
    // revision reads say empty while the intermediate payload contains a story.
    _ = try await cache.value([String].self, scope: ["feed", "one"], revision: "empty", now: now,
      currentRevision: { "empty" }, validatesMembership: { $0.isEmpty }, load: { ["blocked-story"] })
    #expect(await commands.writes == 0)
    let result = try await cache.value([String].self, scope: ["feed", "one"], revision: "empty", now: now,
      currentRevision: { "empty" }, validatesMembership: { $0.isEmpty }, load: { [] })
    #expect(result.isEmpty)
  }


  @Test("edition subset ABA cannot populate a complete-revision cache or survive hit validation")
  func editionSubsetABA() async throws {
    let commands = CorpusCacheCommands()
    let cache = WireCorpusPayloadCache(commands: commands, environment: "prod")
    let revision = "[\"top\",0,\"a\",\"v1\"]\n[\"top\",1,\"b\",\"v2\"]"
    let expected = try #require(RedisPayloadMembership.fields(in: revision, indices: [0, 2]))
    let subset = [["top", "a"]]
    _ = try await cache.value([[String]].self, scope: ["edition", "aba"], revision: revision, now: now,
      currentRevision: { revision },
      validatesMembership: { RedisPayloadMembership.matches($0, expected: expected) }, load: { subset })
    #expect(await commands.writes == 0)
    // Simulate an entry written before exact-membership validation was introduced.
    _ = try await cache.value([[String]].self, scope: ["edition", "aba"], revision: revision, now: now,
      currentRevision: { revision }, load: { subset })
    #expect(await commands.writes == 1)
    let restored = try await cache.value([[String]].self, scope: ["edition", "aba"], revision: revision, now: now.addingTimeInterval(120),
      currentRevision: { revision },
      validatesMembership: { RedisPayloadMembership.matches($0, expected: expected) }, load: { expected })
    #expect(restored == expected)
    #expect(await commands.writes == 2)
    #expect(!RedisPayloadMembership.matches([["top", "a"]], expected: [["top", "a"], ["top", "a"]]))
  }

}
