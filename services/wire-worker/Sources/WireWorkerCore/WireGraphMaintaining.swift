import Foundation

protocol WireGraphMaintaining: Sendable {
  /// Returns the next due date, including a previous owner's persisted assignment deadline.
  func maintainGraph(asOf: Date) async throws -> Date
}

extension PostgresWireInboxProcessor: WireGraphMaintaining {}
