import Foundation

protocol WireInboxProcessing: Sendable {
  func process(asOf: Date) async throws -> Int
}

extension PostgresWireInboxProcessor: WireInboxProcessing {}

protocol WireInboxMaintaining: Sendable {
  func maintain(asOf: Date) async throws
}

extension PostgresWireInboxProcessor: WireInboxMaintaining {}
