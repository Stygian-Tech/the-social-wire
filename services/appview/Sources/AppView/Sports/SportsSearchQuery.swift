import Foundation
import WireCore

/// Browser URLSearchParams uses form encoding: raw '+' is a space, '%2B' is a plus.
enum SportsSearchQuery {
  static func decode(_ rawQuery: String?) throws -> String {
    guard let rawQuery else { throw WireServingError.invalidCursor }
    for component in rawQuery.split(separator: "&", omittingEmptySubsequences: false) {
      let pair = component.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard let key = String(pair[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding else {
        throw WireServingError.invalidCursor
      }
      guard key == "q" else { continue }
      guard pair.count == 2,
        let value = String(pair[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding else {
        throw WireServingError.invalidCursor
      }
      return value
    }
    throw WireServingError.invalidCursor
  }
}
