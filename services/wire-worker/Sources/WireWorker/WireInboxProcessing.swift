import Foundation

protocol WireInboxProcessing: Sendable {
  func process(asOf: Date) async throws -> Int
}

extension PostgresWireInboxProcessor: WireInboxProcessing {}
