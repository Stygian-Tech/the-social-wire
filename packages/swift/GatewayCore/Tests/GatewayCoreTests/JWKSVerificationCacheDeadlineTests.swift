import AsyncHTTPClient
import Foundation
import Hummingbird
import HummingbirdTesting
import Logging
import NIOCore
import Testing

@testable import GatewayCore

@Suite("JWKS cache load deadlines", .timeLimit(.minutes(1)))
struct JWKSVerificationCacheDeadlineTests {
  @Test("an abandoned load expires but retains its admission slot until cancellation completes")
  func abandonedLoadReleasesCapacityAfterCleanup() async throws {
    let cache = JWKSVerificationCache<String>(loadTimeout: .milliseconds(100), maximumInFlight: 1)
    let probe = CancellationProbe()
    let owner = Task {
      try await cache.value(forKey: "issuer", ttl: { _ in 300 }) { try await probe.load() }
    }
    await probe.waitUntilStarted()
    owner.cancel()
    await #expect(throws: CancellationError.self) { try await owner.value }
    // No caller remains, but the cache must still cancel the load at its deadline.
    await probe.waitUntilCancelled()
    await #expect(throws: JWKSVerificationCache<String>.CacheError.overloaded) {
      try await cache.value(forKey: "other", ttl: { _ in 300 }) { "untracked-overlap" }
    }
    await probe.finishCleanup()
    // The actor processes completion asynchronously; retry admission while the
    // cancelled load finishes, without freeing its slot prematurely.
    let retryDeadline = ContinuousClock.now.advanced(by: .seconds(1))
    while true {
      do {
        let value = try await cache.value(forKey: "other", ttl: { _ in 300 }) { "retried" }
        #expect(value == "retried")
        break
      } catch JWKSVerificationCache<String>.CacheError.overloaded {
        guard ContinuousClock.now < retryDeadline else {
          Issue.record("Cancelled load did not release its admission slot")
          return
        }
        try await Task.sleep(for: .milliseconds(10))
      }
    }
    #expect(await cache.cachedValue(forKey: "issuer") == nil)
  }

  @Test("a real HTTP body stall times out fail closed and permits a later JWKS retry")
  func stalledHTTPBody() async throws {
    let upstream = Router()
    upstream.get("/keys") { _, _ -> Response in
      Response(status: .ok, body: ResponseBody { writer in
        try await writer.write(ByteBuffer(string: "{\"keys\":"))
        try await Task.sleep(for: .seconds(3))
        try await writer.write(ByteBuffer(string: "[]}"))
        try await writer.finish(nil)
      })
    }
    let client = HTTPClient(eventLoopGroupProvider: .singleton)
    let cache = JWKSVerificationCache<OAuthAccessTokenVerifier.JWKSFetchResult>(loadTimeout: .milliseconds(150))
    do {
      try await Application(router: upstream).test(.live) { server in
        let port = try #require(server.port)
        let url = "https://issuer.public.social/jwks"
        let start = ContinuousClock.now
        var error: any Error = OAuthAccessTokenVerifier.VerifyError.signatureRejected
        do {
          _ = try await OAuthAccessTokenVerifier.verifyAgainstRemoteJWKS(
            accessTokenJWT: "unused", url: url, httpClient: client,
            logger: Logger(label: "jwks-deadline.test"), probeError: &error, cache: cache,
            fetch: {
              let response = try await client.execute(
                HTTPClientRequest(url: "http://localhost:\(port)/keys"), timeout: .seconds(10))
              return .content(String(buffer: try await response.body.collect(upTo: 512 * 1024)))
            })
          Issue.record("A stalled JWKS body must exceed the cache deadline")
        } catch {
          #expect(error as? JWKSVerificationCache<OAuthAccessTokenVerifier.JWKSFetchResult>.CacheError == .timedOut)
          #expect(!OAuthAccessTokenVerifier.permitsActivePDSFallback(error: error, supplementalJwksJSON: nil))
        }
        #expect(start.duration(to: .now) < .milliseconds(1_500))
        #expect(await cache.cachedValue(forKey: url) == nil)
        _ = try await OAuthAccessTokenVerifier.verifyAgainstRemoteJWKS(
          accessTokenJWT: "unused", url: url, httpClient: client,
          logger: Logger(label: "jwks-deadline.test"), probeError: &error, cache: cache,
          fetch: { .content(#"{"keys":[]}"#) })
        guard case OAuthAccessTokenVerifier.VerifyError.jwksEmpty = error else {
          Issue.record("The next real empty JWKS response should retain its attestation classification")
          return
        }
      }
    } catch {
      try await client.shutdown()
      throw error
    }
    try await client.shutdown()
  }

  private actor CancellationProbe {
    private var started = false
    private var cancelled = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var cancelWaiter: CheckedContinuation<Void, Never>?
    private var cleanup: CheckedContinuation<Void, Never>?

    func load() async throws -> String {
      started = true
      startWaiter?.resume()
      startWaiter = nil
      do {
        try await Task.sleep(for: .seconds(60))
        return "unexpected"
      } catch {
        cancelled = true
        cancelWaiter?.resume()
        cancelWaiter = nil
        await withCheckedContinuation { cleanup = $0 }
        throw error
      }
    }
    func waitUntilStarted() async {
      if started { return }
      await withCheckedContinuation { startWaiter = $0 }
    }
    func waitUntilCancelled() async {
      if cancelled { return }
      await withCheckedContinuation { cancelWaiter = $0 }
    }
    func finishCleanup() { cleanup?.resume(); cleanup = nil }
  }
}
