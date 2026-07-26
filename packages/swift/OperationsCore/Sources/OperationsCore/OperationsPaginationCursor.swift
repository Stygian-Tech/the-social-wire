import Foundation

/// Opaque keyset-pagination cursor shared by Operations stores and HTTP routes.
///
/// A supplied cursor is either valid in full or rejected. Treating malformed input as an absent
/// cursor would silently return the first page and could make an operator believe they had reached
/// a complete result set.
public struct OperationsPaginationCursor: Equatable, Sendable {
  public let date: Date
  public let id: String

  public init(date: Date, id: String) {
    self.date = date
    self.id = id
  }

  public static func encode(date: Date, id: String) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return Data("\(formatter.string(from: date))|\(id)".utf8).base64EncodedString()
  }

  public static func decode(_ rawValue: String) -> OperationsPaginationCursor? {
    guard rawValue.count <= 1_024,
      let data = Data(base64Encoded: rawValue),
      data.base64EncodedString() == rawValue,
      let value = String(data: data, encoding: .utf8),
      let separator = value.firstIndex(of: "|")
    else { return nil }

    let dateText = String(value[..<separator])
    let id = String(value[value.index(after: separator)...])
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard !id.isEmpty, id.count <= 512,
      id.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }),
      let date = formatter.date(from: dateText)
    else { return nil }
    return OperationsPaginationCursor(date: date, id: id)
  }
}
