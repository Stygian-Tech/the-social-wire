import Foundation

enum PDSListRecordsCursor {
  enum ParseResult: Equatable {
    case end
    case next(String)
    case invalid(String)
  }

  static func parse(
    json: [String: Any],
    current: String?,
    seen: Set<String>,
    pageIsEmpty: Bool
  ) -> ParseResult {
    guard json.keys.contains("cursor") else { return .end }
    guard let raw = json["cursor"] as? String else { return .invalid("cursor_not_string") }
    let cursor = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cursor.isEmpty else { return .invalid("cursor_empty") }
    guard cursor != current, !seen.contains(cursor) else { return .invalid("cursor_cycle") }
    guard !pageIsEmpty else { return .invalid("empty_page_with_cursor") }
    return .next(cursor)
  }
}
