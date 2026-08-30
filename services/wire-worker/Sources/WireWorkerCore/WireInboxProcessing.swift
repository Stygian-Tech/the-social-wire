import Foundation

protocol WireInboxProcessing: Sendable {
  func process(asOf: Date) async throws -> Int
  func processWithMetrics(asOf: Date) async throws -> WireInboxDrainBatchMetrics
}

extension WireInboxProcessing {
  func processWithMetrics(asOf: Date) async throws -> WireInboxDrainBatchMetrics {
    let count = try await process(asOf: asOf)
    return WireInboxDrainBatchMetrics(attemptedEventCount: count, appliedEventCount: count)
  }
}

extension PostgresWireInboxProcessor: WireInboxProcessing {}

protocol WireInboxBacklogObserving: Sendable {
  func actionableBacklogHealth(asOf: Date) async throws -> WireInboxBacklogHealth
}

extension PostgresWireInboxProcessor: WireInboxBacklogObserving {}

protocol WireInboxMaintaining: Sendable {
  func maintain(asOf: Date) async throws
}

protocol WireInboxCleaning: Sendable {
  func deleteTerminal(asOf: Date, batchSize: Int) async throws -> Int
}

extension PostgresWireInboxProcessor: WireInboxMaintaining {}
extension PostgresWireInboxProcessor: WireInboxCleaning {}
