import AsyncHTTPClient
import Foundation
import GatewayCore
import Hummingbird
import HummingbirdTesting
import Logging
import NIOCore
import OperationsCore
import Testing

@testable import Gateway

@Suite("Gateway serving and ingestion health")
struct GatewayIngestionHealthTests {
  @Test("missing and unobserved ingestion evidence stays unknown")
  func missing() async throws {
    let health = GatewayIngestionHealth(baseURL: nil) { _ in
      Issue.record("Missing Pool must not be contacted")
      return 200
    }
    #expect(await health.snapshot().checkedAt == nil)
    try await health.collectOnce()
    let snapshot = await health.snapshot()
    #expect(snapshot.poolReadiness == "not_configured")
    #expect(snapshot.completeness == .unknown)
    #expect(snapshot.checkedAt == nil)
  }

  @Test("a fresh sample expires without inventing a new observation", arguments: [UInt(200), 503])
  func sampleExpiry(status: UInt) async throws {
    let at = Date(timeIntervalSince1970: 1_000)
    let clock = HealthTestValue(at)
    let health = GatewayIngestionHealth(baseURL: "http://pool/", lifetime: 45,
      now: { clock.withLock { $0 } }) { url in
      #expect(url == "http://pool")
      return status
    }
    try await health.collectOnce()
    let fresh = await health.snapshot()
    #expect(fresh.checkedAt == at)
    #expect(fresh.completeness == (status == 200 ? .unknown : .degraded))
    #expect(fresh.freshness == .unknown)
    clock.withLock { $0 = at.addingTimeInterval(45) }
    let stale = await health.snapshot()
    #expect(stale.poolReadiness == "stale")
    #expect(stale.completeness == .unknown)
    #expect(stale.checkedAt == at)
    clock.withLock { $0 = at.addingTimeInterval(-1) }
    #expect(await health.snapshot().poolReadiness == "stale")
  }

  @Test("network failure is explicit degradation, cancellation preserves the last sample")
  func errorsAndCancellation() async throws {
    let failed = GatewayIngestionHealth(baseURL: "http://pool") { _ in
      throw HTTPClientError.connectTimeout
    }
    try await failed.collectOnce()
    #expect(await failed.snapshot().poolReadiness == "unavailable")
    #expect(await failed.snapshot().completeness == .degraded)
    let cancelled = GatewayIngestionHealth(baseURL: "http://pool") { _ in
      throw CancellationError()
    }
    await #expect(throws: CancellationError.self) { try await cancelled.collectOnce() }
    #expect(await cancelled.snapshot().checkedAt == nil)
  }

  @Test("a blocked collector does not block snapshot reads or overlap another collection")
  func noOverlap() async throws {
    let started = AsyncStream<Void>.makeStream()
    let calls = HealthTestValue(0)
    let health = GatewayIngestionHealth(baseURL: "http://pool") { _ in
      let call = calls.withLock { $0 += 1; return $0 }
      if call > 1 { return 200 }
      started.continuation.yield(())
      try await Task.sleep(for: .seconds(60))
      return 200
    }
    let task = Task { try await health.collectOnce() }
    for await _ in started.stream { break }
    #expect(await health.snapshot().poolReadiness == "unobserved")
    try await health.collectOnce()
    #expect(calls.withLock { $0 } == 1)
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await health.snapshot().checkedAt == nil)
    try await health.collectOnce()
    #expect(await health.snapshot().poolReadiness == "ready")
    #expect(calls.withLock { $0 } == 2)
  }

  @Test("the independent HTTP probe bounds headers and body", arguments: [false, true])
  func httpDeadline(stallBody: Bool) async throws {
    let requests = HealthTestValue(0)
    let router = Router()
    router.get("/readyz") { _, _ -> Response in
      requests.withLock { $0 += 1 }
      if !stallBody { try await Task.sleep(for: .seconds(2)) }
      return Response(status: .ok, body: ResponseBody { writer in
        try await writer.write(ByteBuffer(string: "{"))
        if stallBody { try await Task.sleep(for: .seconds(2)) }
        try await writer.write(ByteBuffer(string: "}"))
        try await writer.finish(nil)
      })
    }
    let client = HTTPClient(eventLoopGroupProvider: .singleton)
    do {
      try await Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
        .test(.live) { upstream in
          let port = try #require(upstream.port)
          let start = ContinuousClock.now
          await #expect(throws: GatewayDependencyHTTPProbe.ProbeError.self) {
            try await GatewayDependencyHTTPProbe.status(baseURL: "http://localhost:\(port)",
              httpClient: client, timeout: .milliseconds(200))
          }
          #expect(start.duration(to: .now) < .seconds(1))
          #expect(requests.withLock { $0 } == 1)
        }
    } catch {
      try await client.shutdown()
      throw error
    }
    try await client.shutdown()
  }

  @Test("serving readiness depends on AppView and cached degradation never gains a newer expiry",
        arguments: [true, false], [
          (UInt(200), TimeInterval(45)), (UInt(200), TimeInterval(5)),
          (UInt(503), TimeInterval(45)), (UInt(503), TimeInterval(5)),
        ])
  func servingReadiness(appViewReady: Bool, poolEvidence: (UInt, TimeInterval)) async throws {
    let (poolStatus, evidenceLifetime) = poolEvidence
    let calls = HealthTestValue(0)
    let health = GatewayIngestionHealth(baseURL: "http://pool", lifetime: evidenceLifetime) { _ in
      calls.withLock { $0 += 1 }
      return poolStatus
    }
    try await health.collectOnce()
    let upstream = Router()
    upstream.get("/readyz") { _, _ in Response(status: appViewReady ? .ok : .serviceUnavailable) }
    let client = HTTPClient(eventLoopGroupProvider: .singleton)
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("gateway-health-\(UUID()).sqlite").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    do {
      try await Application(router: upstream, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
        .test(.live) { upstream in
          let port = try #require(upstream.port)
          let config = try GatewayServiceConfig.fromEnvironment([
            "APP_ENV": "local", "SQLITE_DB_PATH": path,
            "APPVIEW_BASE_URL": "http://localhost:\(port)",
          ])
          let cache = try SQLiteCache(path: path, logger: Logger(label: "health-test"))
          let operations = try SQLiteOperationsStore(path: path, environment: "test", logger: Logger(label: "health-test"))
          let router = GatewayRouterBuilder.router(config: config, httpClient: client,
            cache: cache, ingestionHealth: health, operationsStore: operations, logger: Logger(label: "health-test"))
          try await Application(router: router).test(.router) { gateway in
            let ready = try await gateway.execute(uri: "/readyz", method: .get)
            #expect(ready.status == (appViewReady ? .ok : .serviceUnavailable))
            if appViewReady {
              #expect(String(buffer: ready.body).contains(poolStatus == 200 ? "unknown" : "failed_http_503"))
              #expect(String(buffer: ready.body).contains(poolStatus == 200 ? "unknown" : "degraded"))
            } else {
              #expect(!String(buffer: ready.body).contains("127.0.0.1"))
            }
            let fresh = try await gateway.execute(uri: "/freshness", method: .get)
            #expect(fresh.status == .ok)
            #expect(String(buffer: fresh.body).contains(poolStatus == 200 ? "unknown" : "degraded"))
            #expect(calls.withLock { $0 } == 1)
          }
          let evidence = try await Serve.gatewayDependencyProbe(
            appViewBaseURL: "http://localhost:\(port)", ingestionHealth: health, httpClient: client)()
          #expect(evidence.readiness == (appViewReady ? .healthy : .degraded))
          #expect(evidence.completeness == (evidenceLifetime >= 30 && poolStatus != 200 ? .degraded : .unknown))
          #expect(evidence.dependencyState["ingestion_completeness"] == evidence.completeness.rawValue)
          #expect(evidence.dependencyState["projection_pool"] ==
            (evidenceLifetime < 30 ? "stale" : poolStatus == 200 ? "ready" : "failed_http_503"))
          let original = await health.snapshot()
          #expect(evidence.dependencyState["ingestion_observed_at"] == original.dependencyState["ingestion_observed_at"])
          #expect(evidence.dependencyState["ingestion_valid_until"] == original.dependencyState["ingestion_valid_until"])
          #expect(evidence.requiredDependencyKeys == ["appview"])
        }
    } catch {
      try await client.shutdown()
      throw error
    }
    try await client.shutdown()
  }
}

/// All fixture access is synchronous and serialized by the lock.
private final class HealthTestValue<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value
  init(_ value: Value) { self.value = value }
  func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
    lock.lock()
    defer { lock.unlock() }
    return body(&value)
  }
}
