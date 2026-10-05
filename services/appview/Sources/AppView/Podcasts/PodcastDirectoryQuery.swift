import Foundation
import ThinAppViewCore

/// Directory queries are explicitly public names/topics; URL and credential-shaped input stays local.
enum PodcastDirectoryQuery {
  static func validate(_ input: PodcastSearchRequest) throws -> String {
    try input.validate()
    guard input.scope == "directory", input.cursor == nil, input.showId == nil,
      ["all", "shows"].contains(input.kind ?? "all") else { throw PodcastDirectoryError.invalidRequest }
    let query = input.query.trimmingCharacters(in: .whitespacesAndNewlines)
    let decoded = query.removingPercentEncoding ?? query
    let patterns = [
      #"(?i)(https?\s*:|at://|www\.|\b[a-z0-9.-]+\.[a-z]{2,}/|[?&=]|\b(?:bearer|dpop)\s+|\b(?:token|password|secret|api[-_ ]?key|authorization)\s*:)"#,
      #"%[0-9A-Fa-f]{2}"#,
      #"[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,}"#,
      #"\b[A-Za-z0-9_+/-]{32,}\b"#,
    ]
    guard !decoded.contains("@"), !decoded.contains(where: { $0.isNewline }),
      patterns.allSatisfy({ decoded.range(of: $0, options: .regularExpression) == nil })
    else { throw PodcastDirectoryError.invalidQuery }
    return query
  }
}
