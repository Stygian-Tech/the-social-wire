import Foundation
import Logging
import PostgresNIO

/// Error descriptions may contain SQL, record values, or connection credentials.
enum WireCorpusErrorDiagnostics {
  static func metadata(_ error: any Error) -> Logger.Metadata {
    if let postgres = error as? PSQLError {
      var fields: Logger.Metadata = ["category": "postgres"]
      if let state = postgres.serverInfo?[.sqlState],
        state.utf8.count == 5,
        state.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }) {
        fields["sqlState"] = .string(state)
      }
      return fields
    }
    if error is DecodingError { return ["category": "decode"] }
    if error is EncodingError { return ["category": "encode"] }
    return ["category": "other"]
  }
}
