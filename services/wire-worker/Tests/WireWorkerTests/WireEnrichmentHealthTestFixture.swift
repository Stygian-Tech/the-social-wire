import Foundation
import Logging
import PostgresNIO

@testable import WireWorkerCore

enum WireEnrichmentHealthTestFixture {
  static func withSchema(
    url: String,
    logger: Logger,
    body: (PostgresClient, PostgresClient.Configuration) async throws -> Void
  ) async throws {
    var configuration = try PostgresWireConfig.make(from: url, logger: logger)
    configuration.options.maximumConnections = 1
    let admin = PostgresClient(configuration: configuration, backgroundLogger: logger)
    let adminRunner = Task { await admin.run() }
    defer { adminRunner.cancel() }
    let schema = "enrichment_health_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    try await admin.query(PostgresQuery(unsafeSQL: "CREATE SCHEMA \(schema)"), logger: logger)
    do {
      // These diagnostics count the whole corpus. A unique row key cannot
      // isolate their totals or table locks from concurrently running suites.
      for table in ["wire_items", "wire_link_metadata_cache", "wire_item_mentions", "wire_talked_accounts"] {
        try await admin.query(PostgresQuery(unsafeSQL:
          "CREATE TABLE \(schema).\(table) (LIKE public.\(table) INCLUDING ALL)"), logger: logger)
      }
      configuration.options.additionalStartupParameters = [("search_path", schema)]
      let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
      let runner = Task { await pool.run() }
      do {
        try await body(pool, configuration)
      } catch {
        runner.cancel()
        await runner.value
        throw error
      }
      runner.cancel()
      await runner.value
    } catch {
      _ = try? await admin.query(PostgresQuery(unsafeSQL: "DROP SCHEMA \(schema) CASCADE"), logger: logger)
      throw error
    }
    try await admin.query(PostgresQuery(unsafeSQL: "DROP SCHEMA \(schema) CASCADE"), logger: logger)
  }
}
