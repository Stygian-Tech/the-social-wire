import Foundation

public enum ReadStateMigrationPlanner {
  /// Row order comes from a revision-fenced export. No source data is deleted here.
  /// Per-row ordering preserves explicit unread precedence and original read times.
  public static func operations(rows: [ReadStateLegacyRow], migrationId: String) throws -> [ReadStateOperation] {
    guard !migrationId.isEmpty, migrationId.utf8.count <= 100 else { throw ReadStateError.invalidRecord }
    var previousPhase = 0
    return try rows.enumerated().map { index, row in
      let phase: Int
      switch row.kind { case .boundary: phase = 0; case .unread: phase = 1; case .read: phase = 2 }
      guard phase >= previousPhase else { throw ReadStateError.invalidRecord }
      previousPhase = phase
      let actionId = "\(migrationId)-\(index)"
      let operation: ReadStateOperation
      switch row.kind {
      case .boundary:
        guard let boundary = row.boundary, row.subjectUri == nil else { throw ReadStateError.invalidRecord }
        operation = ReadStateOperation(actionId: actionId, sequence: Int64(index + 1), state: .read,
          actedAt: row.actedAt, boundaries: [boundary])
      case .read, .unread:
        guard let uri = row.subjectUri, row.boundary == nil else { throw ReadStateError.invalidRecord }
        operation = ReadStateOperation(actionId: actionId, sequence: Int64(index + 1),
          state: row.kind == .read ? .read : .unread, actedAt: row.actedAt, subjectUris: [uri])
      }
      try ReadStateValidation.validate(operation)
      return operation
    }
  }
}
