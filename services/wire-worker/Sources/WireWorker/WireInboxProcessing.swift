import Foundation

protocol WireInboxProcessing: Sendable {
  func process(asOf: Date) async throws -> Int
}

extension PostgresWireInboxProcessor: WireInboxProcessing {}

protocol WireInboxMaintaining: Sendable {
  func maintain(asOf: Date) async throws
}

protocol WireInboxCleaning: Sendable {
  func deleteTerminal(asOf: Date, batchSize: Int) async throws -> Int
}

extension PostgresWireInboxProcessor: WireInboxMaintaining {}
extension PostgresWireInboxProcessor: WireInboxCleaning {}
