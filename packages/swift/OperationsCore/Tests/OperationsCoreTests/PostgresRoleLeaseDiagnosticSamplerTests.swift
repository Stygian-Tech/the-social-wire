import Foundation
import Logging
import PostgresNIO
import Testing

@testable import OperationsCore

@Suite("Lease failure diagnostic safety")
struct PostgresRoleLeaseDiagnosticSamplerTests {
  @Test("each role is sampled at most once per minute using monotonic time")
  func rateLimit() async {
    let recorder = LeaseDiagnosticTestRecorder()
    let clock = LeaseDiagnosticTestClock()
    let sampler = PostgresRoleLeaseDiagnosticSampler(
      environment: "dev", logger: recorder.logger,
      monotonicNow: { clock.now }, processNow: { Date(timeIntervalSince1970: 42) },
      load: { _ in Self.snapshot })
    await sampler.capture(role: "indexing.one")
    await sampler.capture(role: "indexing.one")
    await sampler.capture(role: "indexing.two")
    #expect(recorder.entries.count == 2)
    clock.advance(.seconds(59))
    await sampler.capture(role: "indexing.one")
    #expect(recorder.entries.count == 2)
    clock.advance(.seconds(1))
    await sampler.capture(role: "indexing.one")
    #expect(recorder.entries.count == 3)
    #expect(recorder.entries.last?["process_time"] == Date(timeIntervalSince1970: 42).ISO8601Format())
  }

  @Test("simultaneous roles cannot overlap diagnostic captures")
  func nonoverlap() async {
    let recorder = LeaseDiagnosticTestRecorder()
    let gate = LeaseDiagnosticTestGate()
    let sampler = PostgresRoleLeaseDiagnosticSampler(
      environment: "dev", logger: recorder.logger,
      load: { _ in await gate.wait(); return Self.snapshot })
    let first = Task { await sampler.capture(role: "indexing.one") }
    await gate.waitUntilStarted()
    await sampler.capture(role: "indexing.two")
    #expect(await gate.count == 1)
    await gate.release()
    await first.value
    let second = Task { await sampler.capture(role: "indexing.two") }
    await gate.waitUntilStarted()
    #expect(await gate.count == 2)
    await gate.release()
    await second.value
    #expect(recorder.entries.count == 2)
  }

  @Test("errors never expose SQL, parameters or raw server details and still consume the rate limit")
  func errorPrivacy() async {
    let recorder = LeaseDiagnosticTestRecorder()
    let sampler = PostgresRoleLeaseDiagnosticSampler(
      environment: "dev", logger: recorder.logger,
      load: { _ in throw LeaseDiagnosticSecretError() })
    await sampler.capture(role: "indexing.one")
    await sampler.capture(role: "indexing.one")
    #expect(recorder.entries.count == 1)
    #expect(recorder.entries.first?["failure"] == "unknown")
    #expect(recorder.entries.first?["availability"] == "unavailable")
    #expect(!String(describing: recorder.entries).contains("private_sql_parameter"))
    #expect(Set(recorder.entries.first?.keys.map { $0 } ?? []) == [
      "environment", "role", "failure", "availability", "process_time", "capture_ms",
    ])
  }

  @Test("snapshot fields are allowlisted and bounded; malformed scope is never logged")
  func boundedShape() async {
    let recorder = LeaseDiagnosticTestRecorder()
    let sampler = PostgresRoleLeaseDiagnosticSampler(
      environment: "dev", logger: recorder.logger, load: { _ in Self.snapshot })
    await sampler.capture(role: "invalid\nrole")
    #expect(recorder.entries.isEmpty)
    await sampler.capture(role: "indexing.one")
    let metadata = recorder.entries.first ?? [:]
    #expect(Set(metadata.keys) == [
      "environment", "role", "availability", "database_time", "process_time", "capture_ms",
      "lease_present", "owner_id", "fencing_token", "lease_expires_at",
      "connections_total", "connections_active", "connections_idle", "connections_waiting",
      "backend_samples_truncated", "backends",
    ])
    #expect(metadata["owner_id"] == "owner-first")
    #expect(metadata["backend_samples_truncated"] == "true")
    #expect(!String(describing: metadata).contains("SELECT"))
    #expect(Self.snapshot.metadata["backends"]?.description.components(separatedBy: "wait_event_type").count == 17)
  }

  private static var snapshot: RoleLeaseDiagnosticSnapshot {
    .init(databaseTime: Date(timeIntervalSince1970: 40), ownerID: "owner\nfirst", fencingToken: 7,
      expiresAt: Date(timeIntervalSince1970: 100), totalConnections: 20,
      activeConnections: 4, idleConnections: 16, waitingConnections: 17,
      backends: (0..<20).map { .init(pid: $0 + 1, waitEventType: "Lock", waitEvent: "transactionid",
        blockingPIDs: Array(1...20), blockersTruncated: true) }, sampledBackendCandidates: 20)
  }
}

final class LeaseDiagnosticTestRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [[String: String]] = []
  var entries: [[String: String]] { lock.withLock { recorded } }
  var logger: Logger { Logger(label: "lease-diagnostic-test", factory: { _ in LeaseDiagnosticTestLogHandler(recorder: self) }) }
  func append(_ metadata: Logger.Metadata) {
    lock.withLock { recorded.append(metadata.mapValues { $0.description }) }
  }
}

private struct LeaseDiagnosticTestLogHandler: LogHandler {
  let recorder: LeaseDiagnosticTestRecorder
  var metadata: Logger.Metadata = [:]
  var logLevel: Logger.Level = .trace
  subscript(metadataKey key: String) -> Logger.Metadata.Value? {
    get { metadata[key] }
    set { metadata[key] = newValue }
  }
  #if compiler(>=6.4)
  func log(event: LogEvent) {
    recorder.append(self.metadata.merging(event.metadata ?? [:]) { _, value in value })
  }
  #endif

  func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?,
    source: String, file: String, function: String, line: UInt) {
    recorder.append(self.metadata.merging(metadata ?? [:]) { _, value in value })
  }
}

private final class LeaseDiagnosticTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var instant = ContinuousClock.now
  var now: ContinuousClock.Instant { lock.withLock { instant } }
  func advance(_ duration: Duration) { lock.withLock { instant = instant.advanced(by: duration) } }
}

private struct LeaseDiagnosticSecretError: Error, CustomStringConvertible {
  var description: String { "SELECT secret WHERE token = private_sql_parameter" }
}

private actor LeaseDiagnosticTestGate {
  private(set) var count = 0
  private var pending: CheckedContinuation<Void, Never>?
  private var observer: CheckedContinuation<Void, Never>?
  func wait() async {
    count += 1
    await withCheckedContinuation { continuation in
      pending = continuation
      observer?.resume()
      observer = nil
    }
  }
  func waitUntilStarted() async {
    if pending != nil { return }
    await withCheckedContinuation { observer = $0 }
  }
  func release() {
    pending?.resume()
    pending = nil
  }
}
