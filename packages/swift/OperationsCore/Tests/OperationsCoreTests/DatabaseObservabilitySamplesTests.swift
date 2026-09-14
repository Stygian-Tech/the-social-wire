import Foundation
import Logging
import PostgresNIO
import Testing

@testable import OperationsCore

@Suite("Database observation evidence")
struct DatabaseObservabilitySamplesTests {
  @Test("dashboard reads return unavailable without starting or querying a database pool")
  func dashboardDoesNotQuery() async throws {
    let logger = Logger(label: "database-observation-no-queries")
    let pool = PostgresClient(configuration: .init(
      host: "127.0.0.1", port: 1, username: "unused", password: nil, database: "unused", tls: .disable),
      backgroundLogger: logger)
    let store = PostgresOperationsStore(pool: pool, environment: "dev", logger: logger)
    // Deliberately never run the pool: a request-triggered SQL call would wait for a
    // connection. An empty collector cache must return unavailable immediately.
    #expect(try await store.fetchDatabaseObservability() == nil)
    #expect(try await store.fetchDatabaseObservability() == nil)
  }

  @Test("mixed-cadence evidence retains its oldest timestamp on repeated dashboard reads")
  func preservedEvidenceAge() throws {
    var samples = DatabaseObservabilitySamples()
    let start = Date(timeIntervalSince1970: 1_000)
    #expect(samples.snapshot(at: start) == nil)
    samples.record(counters(at: start, transactions: 100))
    #expect(samples.snapshot(at: start) == nil)
    samples.record(DatabaseObservabilitySamples.Tables(
      databaseSizeBytes: 200, estimatedRecords: 10, topTables: [], observedAt: start))
    samples.record(counters(at: start.addingTimeInterval(60), transactions: 220))
    let first = try #require(samples.snapshot(at: start.addingTimeInterval(65)))
    #expect(first.databaseSizeBytes == 200 && first.transactionsTotal == 220)
    #expect(first.transactionRatePerSecond == 2)
    #expect(first.observedAt == start && first.evidenceAgeSeconds == 65)
    let later = try #require(samples.snapshot(at: start.addingTimeInterval(100)))
    #expect(later.observedAt == start && later.evidenceAgeSeconds == 100)
    #expect(later.databaseSizeBytes == first.databaseSizeBytes)
    #expect(later.transactionsTotal == first.transactionsTotal)

    // A table refresh alone cannot refresh older counter evidence either.
    samples.record(DatabaseObservabilitySamples.Tables(
      databaseSizeBytes: 300, estimatedRecords: 12, topTables: [],
      observedAt: start.addingTimeInterval(900)))
    let staleCounters = try #require(samples.snapshot(at: start.addingTimeInterval(905)))
    #expect(staleCounters.observedAt == start.addingTimeInterval(60))
    #expect(staleCounters.evidenceAgeSeconds == 845)
  }

  @Test("counter resets and unavailable observations do not manufacture throughput")
  func resetAndUnavailable() throws {
    var samples = DatabaseObservabilitySamples()
    let start = Date(timeIntervalSince1970: 2_000)
    samples.record(DatabaseObservabilitySamples.Tables(
      databaseSizeBytes: 200, estimatedRecords: 10, topTables: [], observedAt: start))
    #expect(samples.snapshot(at: start) == nil)
    samples.record(counters(at: start, transactions: 100))
    #expect(try #require(samples.snapshot(at: start)).transactionRatePerSecond == nil)
    samples.record(counters(at: start.addingTimeInterval(60), transactions: 10))
    #expect(try #require(samples.snapshot(at: start.addingTimeInterval(60))).transactionRatePerSecond == nil)
  }

  private func counters(at: Date, transactions: Int64) -> DatabaseObservabilitySamples.Counters {
    .init(connections: 2, maxConnections: 100, transactions: transactions,
      cacheHitRatio: nil, statsResetAt: nil, activeQueries: 1, observedAt: at)
  }
}
