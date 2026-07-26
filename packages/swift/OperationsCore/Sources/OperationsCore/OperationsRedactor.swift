import Crypto
import Foundation
import PostgresNIO

public enum OperationsRedactor {
  private static let prohibitedKeys = [
    "authorization", "dpop", "cookie", "token", "secret", "password", "record", "body",
  ]

  public static func boundedAttributes(_ input: [String: String], maximumValueLength: Int = 256) -> [String: String] {
    var result: [String: String] = [:]
    for (key, value) in input.prefix(32) {
      let lower = key.lowercased()
      guard !prohibitedKeys.contains(where: { lower.contains($0) }) else { continue }
      result[key] = String(value.prefix(maximumValueLength))
    }
    return result
  }

  public static func recordIdentifierHash(_ value: String) -> String {
    let digest = SHA256.hash(data: Data(value.utf8))
    return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
  }

  public static func hashIdentity(_ value: String) -> String {
    recordIdentifierHash(value)
  }

  public static func errorCategory(_ error: Error) -> String {
    if let postgresError = postgresError(error),
       let sqlState = postgresError.serverInfo?[.sqlState] {
      let identifiers = [
        postgresError.serverInfo?[.tableName],
        postgresError.serverInfo?[.columnName],
      ].compactMap { $0 }.map(sanitizeIdentifier)
      return (["postgres", sqlState.lowercased()] + identifiers).joined(separator: "_")
    }
    let typeName = String(reflecting: type(of: error)).split(separator: ".").last.map(String.init) ?? "unknown"
    let bounded = typeName.unicodeScalars.map { scalar in
      CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "_"
    }
    return String(String(bounded).prefix(64)).lowercased()
  }

  private static func postgresError(_ error: Error) -> PSQLError? {
    if let postgresError = error as? PSQLError { return postgresError }
    guard let transactionError = error as? PostgresTransactionError else { return nil }
    return [
      transactionError.closureError,
      transactionError.commitError,
      transactionError.beginError,
      transactionError.rollbackError,
    ].compactMap { $0 }.lazy.compactMap(postgresError).first
  }

  private static func sanitizeIdentifier(_ value: String) -> String {
    String(value.unicodeScalars.map { scalar in
      CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "_"
    }.prefix(32)).lowercased()
  }
}
