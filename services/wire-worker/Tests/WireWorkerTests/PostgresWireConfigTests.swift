import Logging
import Testing

@testable import WireWorkerCore

@Suite("The Wire PostgreSQL connection identity")
struct PostgresWireConfigTests {
  @Test("uses the supplied Railway service name without changing the pool ceiling")
  func railwayServiceName() throws {
    let config = try PostgresWireConfig.make(
      from: "postgresql://localhost/wire", maximumConnections: 12,
      environment: ["RAILWAY_SERVICE_NAME": "  Wire Coordinator  "],
      logger: Logger(label: "fallback"))
    #expect(config.options.additionalStartupParameters.count == 1)
    #expect(config.options.additionalStartupParameters.first?.0 == "application_name")
    #expect(config.options.additionalStartupParameters.first?.1 == "Wire-Coordinator")
    #expect(config.options.maximumConnections == 12)
  }

  @Test("missing and blank service names fall back to the logger", arguments: [nil, "", " \n\t"])
  func loggerFallback(service: String?) throws {
    var environment: [String: String] = [:]
    environment["RAILWAY_SERVICE_NAME"] = service
    let config = try PostgresWireConfig.make(
      from: "postgresql://localhost/wire", environment: environment,
      logger: Logger(label: "com.thesocialwire.wire-worker"))
    #expect(config.options.additionalStartupParameters.first?.1 == "com.thesocialwire.wire-worker")
    #expect(config.options.maximumConnections == 2)
  }

  @Test("startup labels replace controls and non-ASCII characters")
  func sanitizedName() throws {
    let config = try PostgresWireConfig.make(
      from: "postgresql://localhost/wire",
      environment: ["RAILWAY_SERVICE_NAME": "Wire\nPool\t\u{0}é🔌_2.0"],
      logger: Logger(label: "fallback"))
    #expect(config.options.additionalStartupParameters.first?.1 == "Wire-Pool----_2.0")
  }

  @Test("startup labels are bounded to 63 bytes after sanitization")
  func byteLimit() throws {
    let config = try PostgresWireConfig.make(
      from: "postgresql://localhost/wire",
      environment: ["RAILWAY_SERVICE_NAME": String(repeating: "é", count: 100)],
      logger: Logger(label: "fallback"))
    let name = try #require(config.options.additionalStartupParameters.first?.1)
    #expect(name == String(repeating: "-", count: 63))
    #expect(name.utf8.count == 63)
  }

  @Test("empty logger names still identify the worker")
  func emptyFallback() throws {
    let config = try PostgresWireConfig.make(
      from: "postgresql://localhost/wire", environment: [:], logger: Logger(label: ""))
    #expect(config.options.additionalStartupParameters.first?.1 == "wire-worker")
  }
}
