import Foundation

/// The response has one evidence timestamp. Use the oldest contributing observation so
/// a fresh counter sample cannot make a fifteen-minute table-size sample look fresh.
struct DatabaseObservabilitySamples: Sendable {
  struct Counters: Sendable {
    let connections: Int64
    let maxConnections: Int64
    let transactions: Int64
    let cacheHitRatio: Double?
    let statsResetAt: Date?
    let activeQueries: Int64
    let observedAt: Date
  }

  struct Tables: Sendable {
    let databaseSizeBytes: Int64
    let estimatedRecords: Int64
    let topTables: [DatabaseTableRecordCount]
    let observedAt: Date
  }

  private var counters: Counters?
  private var tables: Tables?
  private var transactionRate: Double?

  mutating func record(_ value: Counters) {
    if let previous = counters,
      value.observedAt > previous.observedAt,
      value.statsResetAt == previous.statsResetAt,
      value.transactions >= previous.transactions
    {
      transactionRate = Double(value.transactions - previous.transactions)
        / value.observedAt.timeIntervalSince(previous.observedAt)
    } else {
      transactionRate = nil
    }
    counters = value
  }

  mutating func record(_ value: Tables) {
    tables = value
  }

  func snapshot(at: Date) -> DatabaseObservabilitySnapshot? {
    guard let counters, let tables else { return nil }
    let observedAt = min(counters.observedAt, tables.observedAt)
    return DatabaseObservabilitySnapshot(
      databaseSizeBytes: tables.databaseSizeBytes,
      activeConnections: counters.connections,
      maxConnections: counters.maxConnections,
      transactionsTotal: counters.transactions,
      estimatedRecords: tables.estimatedRecords,
      cacheHitRatio: counters.cacheHitRatio,
      statsResetAt: counters.statsResetAt,
      topTables: tables.topTables,
      connectedBackends: counters.connections,
      activeQueries: counters.activeQueries,
      transactionRatePerSecond: transactionRate,
      observedAt: observedAt,
      evidenceAgeSeconds: max(0, at.timeIntervalSince(observedAt)))
  }
}
