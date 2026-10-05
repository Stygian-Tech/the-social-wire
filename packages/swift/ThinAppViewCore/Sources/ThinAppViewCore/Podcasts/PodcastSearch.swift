import Crypto
import Foundation

/// Search only publisher prose. URLs, GUIDs, transcripts and private credentials are not searchable.
public enum PodcastSearch {
  public static func matches(_ query: String, title: String, description: String?, hosts: [PodcastPerson] = []) -> Bool {
    let fields = normalize(([title, description ?? ""] + hosts.map(\.name)).joined(separator: " "))
    return normalize(query).split(whereSeparator: { $0.isWhitespace }).allSatisfy { fields.contains($0) }
  }

  static func normalize(_ value: String) -> String {
    value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
  }

  static func binding(viewer: String, request: PodcastSearchRequest) throws -> String {
    let fields = [viewer, normalize(request.query.trimmingCharacters(in: .whitespacesAndNewlines)), request.kind ?? "all", request.showId ?? ""]
    let data = try JSONEncoder().encode(fields)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
