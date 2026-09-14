import Foundation
import Logging
import PostgresNIO
import Testing
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@testable import OperationsCore

@Suite("Lease diagnostic unavailable transport", .serialized, .enabled(
  if: ProcessInfo.processInfo.environment["OPERATIONS_TEST_DATABASE_URL"] != nil,
  "Requires explicit authorization for disposable local network tests."))
struct PostgresRoleLeaseDiagnosticTransportTests {
  @Test("unavailable and silent database endpoints cannot exceed the acquisition budget", arguments: [false, true])
  func boundedTransport(acceptConnections: Bool) async throws {
    #if canImport(Darwin)
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    #else
    let descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #endif
    try #require(descriptor >= 0)
    defer { _ = close(descriptor) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr = in_addr(s_addr: in_addr_t(0x7f000001).bigEndian)
    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    try #require(bound == 0)
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let resolved = withUnsafeMutablePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(descriptor, $0, &length)
      }
    }
    try #require(resolved == 0)
    // A bound non-listening socket reliably refuses connections. A listening socket
    // completes TCP but never replies to PostgreSQL's startup packet.
    if acceptConnections { try #require(listen(descriptor, 8) == 0) }
    var config = PostgresClient.Configuration(
      host: "127.0.0.1", port: Int(UInt16(bigEndian: address.sin_port)),
      username: "diagnostic-test", password: "private_sql_parameter", database: "diagnostic-test", tls: .disable)
    config.options.minimumConnections = 0
    config.options.maximumConnections = 1
    let logger = Logger(label: "diagnostic-noop", factory: { _ in SwiftLogNoOpLogHandler() })
    let pool = PostgresClient(configuration: config, backgroundLogger: logger)
    let running = Task { await pool.run() }
    defer { running.cancel() }
    let recorder = LeaseDiagnosticTestRecorder()
    let sampler = PostgresRoleLeaseDiagnosticSampler(pool: pool, environment: "dev", logger: recorder.logger)
    let started = ContinuousClock.now
    await sampler.capture(role: "diagnostic.transport")
    #expect(started.duration(to: .now) < .seconds(5))
    #expect(recorder.entries.count == 1)
    #expect(recorder.entries.first?["availability"] == "unavailable")
    #expect(recorder.entries.first?["failure"] == "operationTimedOut")
    #expect(!String(describing: recorder.entries).contains("private_sql_parameter"))
  }
}
