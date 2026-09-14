import AsyncHTTPClient
import Crypto
import Foundation
import Logging
import Synchronization
import Testing

@testable import GatewayCore

@Suite("JWKS discovery cache", .timeLimit(.minutes(1)))
struct JWKSVerificationCacheTests {
  private actor Probe {
    private(set) var calls = 0
    private var release: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func fetch(_ value: String) async throws -> String {
      calls += 1
      started?.resume()
      started = nil
      await withCheckedContinuation { release = $0 }
      try Task.checkCancellation()
      return value
    }
    func waitUntilStarted() async {
      if calls > 0 { return }
      await withCheckedContinuation { started = $0 }
    }
    func unblock() { release?.resume(); release = nil }
    func increment() -> Int { calls += 1; return calls }
  }

  @Test("concurrent legitimate empty JWKS requests share one upstream fetch")
  func emptyJWKSCoalesces() async throws {
    let cache = JWKSVerificationCache<OAuthAccessTokenVerifier.JWKSFetchResult>()
    let probe = Probe()
    let client = HTTPClient(eventLoopGroupProvider: .singleton)
    let tasks = (0..<20).map { _ in Task {
      var error: any Error = OAuthAccessTokenVerifier.VerifyError.signatureRejected
      let token = try await OAuthAccessTokenVerifier.verifyAgainstRemoteJWKS(
        accessTokenJWT: "unused-for-empty-keys", url: "https://issuer.public.social/jwks",
        httpClient: client, logger: Logger(label: "empty-jwks"), probeError: &error,
        cache: cache, fetch: { .content(try await probe.fetch(#"{"keys":[]}"#)) })
      #expect(token == nil)
      guard case OAuthAccessTokenVerifier.VerifyError.jwksEmpty = error else {
        Issue.record("Empty JWKS must require active PDS attestation")
        return
      }
    }}
    await probe.waitUntilStarted()
    await probe.unblock()
    for task in tasks { try await task.value }
    #expect(await probe.calls == 1)
    try await client.shutdown()
  }

  @available(macOS 15.0, *)
  @Test("TTL boundary refetches without extending the cached authority window")
  func ttlBoundary() async throws {
    let instant = Mutex(Date(timeIntervalSince1970: 1_000))
    let cache = JWKSVerificationCache<String>(now: { instant.withLock { $0 } })
    let probe = Probe()
    let load: @Sendable () async throws -> String = { String(await probe.increment()) }
    #expect(try await cache.value(forKey: "issuer", ttl: { _ in 300 }, load: load) == "1")
    instant.withLock { $0 = Date(timeIntervalSince1970: 1_299) }
    #expect(try await cache.value(forKey: "issuer", ttl: { _ in 300 }, load: load) == "1")
    instant.withLock { $0 = Date(timeIntervalSince1970: 1_300) }
    #expect(try await cache.value(forKey: "issuer", ttl: { _ in 300 }, load: load) == "2")
  }

  @Test("failed discovery retries and cancellation leaves the shared fetch running")
  func failureAndCancellation() async throws {
    enum Failure: Error { case unavailable }
    let cache = JWKSVerificationCache<String>()
    await #expect(throws: Failure.self) {
      try await cache.value(forKey: "issuer", ttl: { _ in 300 }) { throw Failure.unavailable }
    }
    let probe = Probe()
    let owner = Task {
      try await cache.value(forKey: "issuer", ttl: { _ in 300 }) { try await probe.fetch("authoritative") }
    }
    await probe.waitUntilStarted()
    owner.cancel()
    // Cancellation must finish before the blocked shared fetch is released.
    await #expect(throws: CancellationError.self) { try await owner.value }
    let peer = Task {
      try await cache.value(forKey: "issuer", ttl: { _ in 300 }) {
        Issue.record("Cancelled owner must not discard shared fetch")
        return "wrong"
      }
    }
    await probe.unblock()
    #expect(try await peer.value == "authoritative")
    #expect(await probe.calls == 1)
  }

  @Test("discovery keys isolate subjects and in-flight capacity fails closed")
  func isolationAndAdmission() async throws {
    let cache = JWKSVerificationCache<String>(maximumEntries: 1, maximumInFlight: 1)
    let probe = Probe()
    let first = Task {
      try await cache.value(forKey: "subject-a", ttl: { _ in 600 }) { try await probe.fetch("a") }
    }
    await probe.waitUntilStarted()
    await #expect(throws: JWKSVerificationCache<String>.CacheError.self) {
      try await cache.value(forKey: "subject-b", ttl: { _ in 600 }) { "b" }
    }
    await probe.unblock()
    #expect(try await first.value == "a")
    let second = try await cache.value(forKey: "subject-b", ttl: { _ in 600 }) { "b" }
    #expect(second == "b")
    #expect(await cache.cachedValue(forKey: "subject-a") == nil)
  }

  @available(macOS 15.0, *)
  @Test("transient HTTP failures retain their type and retry after the existing short TTL")
  func failureTTL() async throws {
    let instant = Mutex(Date(timeIntervalSince1970: 1_000))
    let cache = JWKSVerificationCache<OAuthAccessTokenVerifier.JWKSFetchResult>(
      now: { instant.withLock { $0 } })
    let probe = Probe()
    let client = HTTPClient(eventLoopGroupProvider: .singleton)
    for second in [1_000.0, 1_059.0, 1_060.0] {
      instant.withLock { $0 = Date(timeIntervalSince1970: second) }
      var error: any Error = OAuthAccessTokenVerifier.VerifyError.signatureRejected
      let token = try await OAuthAccessTokenVerifier.verifyAgainstRemoteJWKS(
        accessTokenJWT: "unused", url: "https://issuer.public.social/jwks",
        httpClient: client, logger: Logger(label: "http-failure"), probeError: &error,
        cache: cache, fetch: { _ = await probe.increment(); return .failure(503) })
      #expect(token == nil)
      #expect(!OAuthAccessTokenVerifier.permitsActivePDSFallback(error: error, supplementalJwksJSON: nil))
    }
    #expect(await probe.calls == 2)
    try await client.shutdown()
  }

  @Test("same-key discovery and refresh bursts coalesce without blocking other keys")
  func discoveryAndRefresh() async throws {
    let cache = JWKSVerificationCache<[String]>()
    _ = try await cache.value(forKey: "issuer#subject", ttl: { _ in 600 }) { ["old"] }
    let probe = Probe()
    let tasks = (0..<20).map { _ in Task {
      try await cache.value(forKey: "issuer#subject", refreshing: ["old"], ttl: { _ in 600 }) {
        [try await probe.fetch("new")]
      }
    }}
    await probe.waitUntilStarted()
    let unrelated = try await cache.value(forKey: "issuer#other-subject", ttl: { _ in 600 }) { ["other"] }
    #expect(unrelated == ["other"])
    await probe.unblock()
    for task in tasks { #expect(try await task.value == ["new"]) }
    #expect(await probe.calls == 1)
  }

  @Test("byte budget evicts deterministically and does not cache oversized content")
  func byteBudget() async throws {
    let cache = JWKSVerificationCache<String>(
      maximumCost: 8, cost: { $0.utf8.count }, now: { Date(timeIntervalSince1970: 1_000) })
    for key in ["a", "b", "c"] {
      _ = try await cache.value(forKey: key, ttl: { _ in 300 }) { "abc" }
    }
    // Each one-byte key plus three-byte value costs four bytes. Equal-expiry
    // eviction uses the key order, so the result is deterministic.
    #expect(await cache.cachedValue(forKey: "a") == nil)
    #expect(await cache.cachedValue(forKey: "b") == "abc")
    #expect(await cache.cachedValue(forKey: "c") == "abc")
    let oversized = try await cache.value(forKey: "d", ttl: { _ in 300 }) { "12345678" }
    #expect(oversized == "12345678")
    #expect(await cache.cachedValue(forKey: "d") == nil)
    #expect(await cache.cachedValue(forKey: "b") == "abc")
    #expect(await cache.cachedValue(forKey: "c") == "abc")
  }

  @Test("byte eviction preserves active flights and failed refresh preserves cached content")
  func evictionAndFailure() async throws {
    enum Failure: Error { case unavailable }
    let cache = JWKSVerificationCache<String>(maximumCost: 4, cost: { $0.utf8.count })
    _ = try await cache.value(forKey: "a", ttl: { _ in 300 }) { "old" }
    await #expect(throws: Failure.self) {
      try await cache.value(forKey: "a", refreshing: "old", ttl: { _ in 300 }) {
        throw Failure.unavailable
      }
    }
    #expect(await cache.cachedValue(forKey: "a") == "old")
    let probe = Probe()
    let flight = Task {
      try await cache.value(forKey: "b", ttl: { _ in 300 }) { try await probe.fetch("new") }
    }
    await probe.waitUntilStarted()
    _ = try await cache.value(forKey: "c", ttl: { _ in 300 }) { "now" }
    #expect(await cache.cachedValue(forKey: "a") == nil)
    #expect(await cache.cachedValue(forKey: "c") == "now")
    await probe.unblock()
    #expect(try await flight.value == "new")
    #expect(await cache.cachedValue(forKey: "b") == "new")
    #expect(await cache.cachedValue(forKey: "c") == nil)
    #expect(await probe.calls == 1)
  }

  @Test("nonempty cached JWKS refreshes once for signing-key rotation")
  func rotation() async throws {
    let old = P256.Signing.PrivateKey()
    let current = P256.Signing.PrivateKey()
    let cache = JWKSVerificationCache<OAuthAccessTokenVerifier.JWKSFetchResult>()
    let url = "https://issuer.public.social/jwks"
    let oldJSON = try jwks(old)
    let newJSON = try jwks(current)
    _ = try await cache.value(forKey: url, ttl: { $0.ttl }) { .content(oldJSON) }
    let header = encoded(Data(#"{"alg":"ES256","kid":"key","typ":"JWT"}"#.utf8))
    let payload = try JSONSerialization.data(withJSONObject: [
      "iss": "https://issuer.public.social", "sub": "did:plc:cache-test",
      "exp": Int(Date().addingTimeInterval(3600).timeIntervalSince1970), "cnf": ["jkt": "bound-key"],
    ])
    let input = "\(header).\(encoded(payload))"
    let jwt = "\(input).\(encoded(try current.signature(for: Data(input.utf8)).rawRepresentation))"
    let probe = Probe()
    let client = HTTPClient(eventLoopGroupProvider: .singleton)
    for _ in 0..<2 {
      var error: any Error = OAuthAccessTokenVerifier.VerifyError.signatureRejected
      let token = try await OAuthAccessTokenVerifier.verifyAgainstRemoteJWKS(
        accessTokenJWT: jwt, url: url, httpClient: client, logger: Logger(label: "rotation"),
        probeError: &error, cache: cache,
        fetch: { _ = await probe.increment(); return .content(newJSON) })
      #expect(token?.did == "did:plc:cache-test")
      #expect(token?.cnfJkt == "bound-key")
    }
    #expect(await probe.calls == 1)
    try await client.shutdown()
  }

  private func jwks(_ key: P256.Signing.PrivateKey) throws -> String {
    let coordinates = key.publicKey.x963Representation.dropFirst()
    let data = try JSONSerialization.data(withJSONObject: ["keys": [[
      "kty": "EC", "crv": "P-256", "alg": "ES256", "kid": "key", "use": "sig",
      "x": encoded(Data(coordinates.prefix(32))), "y": encoded(Data(coordinates.suffix(32))),
    ]]])
    return String(decoding: data, as: UTF8.self)
  }
  private func encoded(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
}
