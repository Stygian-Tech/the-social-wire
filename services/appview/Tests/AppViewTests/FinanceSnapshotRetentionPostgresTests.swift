import Foundation
import Logging
import PostgresNIO
import Testing
import ThinAppViewCore
@testable import AppView

@Suite("Finance snapshot retention PostgreSQL", .serialized, .enabled(
  if: ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] != nil,
  "Set WIRE_TEST_DATABASE_URL to an explicitly disposable migrated PostgreSQL database."
))
struct FinanceSnapshotRetentionPostgresTests {
  @Test("imported source expiry cascades snapshots in bounded throttled batches")
  func expiredImportsAreReclaimed() async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "finance-retention.test")
    var configuration = try makePostgresConfig(from: url, logger: logger)
    configuration.options.maximumConnections = 2
    // Feed-serving suites run retention against public tables concurrently. Give
    // this maintenance test its own search path so their sweeps cannot delete its fixtures.
    let schema = "finance_retention_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    configuration.options.additionalStartupParameters.append(("search_path", schema))
    let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
    let run = Task { await pool.run() }
    defer { run.cancel() }
    await Task.yield()
    let now = Date(timeIntervalSince1970: 978_307_200)
    let expiredIDs = (0..<105).map { _ in UUID() }
    let futureID = UUID()
    let allIDs = expiredIDs + [futureID]
    let scope = "retention:" + UUID().uuidString
    do {
      try await pool.query(.init(unsafeSQL: "CREATE SCHEMA \(schema)"), logger: logger)
      try await pool.query("""
        CREATE TABLE finance_generations (LIKE public.finance_generations INCLUDING ALL)
        """, logger: logger)
      try await pool.query("""
        CREATE TABLE finance_personalized_snapshots (LIKE public.finance_personalized_snapshots INCLUDING ALL)
        """, logger: logger)
      // LIKE copies indexes and checks, but PostgreSQL excludes foreign keys.
      try await pool.query("""
        ALTER TABLE finance_personalized_snapshots ADD FOREIGN KEY (source_generation_id)
          REFERENCES finance_generations(generation_id) ON DELETE CASCADE
        """, logger: logger)
      try await pool.query("""
        INSERT INTO finance_generations
          (generation_id,source_generation_id,language,algorithm_version,generated_at,expires_at,payload)
        SELECT id,id,'en','finance-v1',\(now.addingTimeInterval(-48 * 3600)),\(now),'[]'::jsonb
        FROM unnest(\(expiredIDs)::uuid[]) AS fixture(id)
        """, logger: logger)
      try await pool.query("""
        INSERT INTO finance_generations
          (generation_id,source_generation_id,language,algorithm_version,generated_at,expires_at,payload)
        VALUES (\(futureID),\(futureID),'en','finance-v1',\(now),\(now.addingTimeInterval(48 * 3600)),'[]'::jsonb)
        """, logger: logger)
      try await pool.query("""
        INSERT INTO finance_personalized_snapshots
          (snapshot_id,source_generation_id,viewer_scope,language,preference_revision,generated_at,expires_at,payload)
        SELECT id,id,\(scope),'en','retention-fixture',\(now),\(now.addingTimeInterval(48 * 3600)),'[]'::jsonb
        FROM unnest(\(allIDs)::uuid[]) AS fixture(id)
        """, logger: logger)
      let retention = FinanceSnapshotRetention(pool: pool, logger: logger)
      #expect(await retention.purgeIfDue(now: now) == 100)
      try await expectCounts(pool: pool, logger: logger, ids: allIDs, count: 6)
      #expect(await retention.purgeIfDue(now: now.addingTimeInterval(1)) == 0)
      try await expectCounts(pool: pool, logger: logger, ids: allIDs, count: 6)
      #expect(await retention.purgeIfDue(now: now.addingTimeInterval(60)) == 5)
      try await expectCounts(pool: pool, logger: logger, ids: allIDs, count: 1)
    } catch {
      try? await cleanup(pool: pool, logger: logger, schema: schema)
      throw error
    }
    try await cleanup(pool: pool, logger: logger, schema: schema)
  }

  private func expectCounts(pool: PostgresClient, logger: Logger, ids: [UUID], count: Int64) async throws {
    let sources = try await pool.query("SELECT count(*) FROM finance_generations WHERE generation_id=ANY(\(ids)::uuid[])", logger: logger)
    for try await row in sources { #expect(try row.decode(Int64.self) == count) }
    let snapshots = try await pool.query("SELECT count(*) FROM finance_personalized_snapshots WHERE source_generation_id=ANY(\(ids)::uuid[])", logger: logger)
    for try await row in snapshots { #expect(try row.decode(Int64.self) == count) }
  }

  private func cleanup(pool: PostgresClient, logger: Logger, schema: String) async throws {
    try await pool.query(.init(unsafeSQL: "DROP SCHEMA IF EXISTS \(schema) CASCADE"), logger: logger)
  }
}
