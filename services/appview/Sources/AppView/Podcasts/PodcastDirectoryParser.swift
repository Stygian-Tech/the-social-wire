import Crypto
import Foundation
import ThinAppViewCore

/// Podcast Index's official Apple-compatible result schema, verified against its public search API.
enum PodcastDirectoryParser {
  static func parse(_ data: Data) throws -> [PodcastDirectoryCandidate] {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let count = root["resultCount"] as? Int, count >= 0,
      let rows = root["results"] as? [[String: Any]], rows.count <= 1000,
      count == rows.count else { throw PodcastDirectoryError.unavailable }
    var seen = Set<String>()
    var identifiers = Set<String>()
    return Array(rows.compactMap { row -> PodcastDirectoryCandidate? in
      guard row["kind"] as? String == "podcast", let feed = row["feedUrl"] as? String,
        PodcastRSSURL.isAllowed(feed), safePublicURL(feed) != nil,
        let name = (row["collectionName"] ?? row["trackName"]) as? String,
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        seen.insert(feed).inserted else { return nil }
      let identifier = (row["trackId"] as? NSNumber)?.int64Value ?? (row["collectionId"] as? NSNumber)?.int64Value ?? 0
      let id = identifier > 0 ? String(identifier) : SHA256.hash(data: Data(feed.utf8)).map { String(format: "%02x", $0) }.joined()
      guard identifiers.insert(id).inserted else { return nil }
      let artwork = ["artworkUrl600", "artworkUrl100", "artworkUrl60"].compactMap { safePublicURL(row[$0] as? String) }.first
      return PodcastDirectoryCandidate(id: id, title: String(name.prefix(512)),
        description: (row["description"] as? String).map { String($0.prefix(4096)) }, artworkUrl: artwork, feedUrl: feed)
    }.prefix(50))
  }

  static func safePublicURL(_ raw: String?) -> String? {
    guard let raw, raw.count <= 4096, let url = URLComponents(string: raw),
      url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
      let host = url.host?.lowercased(), host.contains("."), !host.contains(":"),
      host != "localhost", !host.hasSuffix(".localhost"), !host.hasSuffix(".local"), !host.hasSuffix(".internal"),
      host.split(separator: ".").last?.allSatisfy({ $0.isLetter }) == true,
      url.fragment == nil, url.url != nil
    else { return nil }
    return raw
  }
}
