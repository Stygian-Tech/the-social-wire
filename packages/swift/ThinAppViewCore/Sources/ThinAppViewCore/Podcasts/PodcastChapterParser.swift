import Foundation

/// Publisher JSON chapters, plus normalized chapter arrays from supported protocol records.
public enum PodcastChapterParser {
  public static func parse(_ data: Data, duration: Double? = nil) -> [PodcastChapter] {
    guard let value = try? JSONSerialization.jsonObject(with: data) else { return [] }
    let rows = (value as? [String: Any])?["chapters"] as? [[String: Any]] ?? value as? [[String: Any]] ?? []
    return chapters(rows, duration: duration)
  }
  public static func chapters(_ rows: [[String: Any]], duration: Double? = nil) -> [PodcastChapter] {
    rows.prefix(1000).compactMap { row -> PodcastChapter? in
      guard row["toc"] as? Bool != false,
        let start = (row["startSeconds"] ?? row["startTime"] ?? row["start"]) as? Double,
        start.isFinite, start >= 0, duration.map({ start < $0 }) ?? true
      else { return nil }
      return PodcastChapter(startSeconds: start,
        title: String(((row["title"] as? String) ?? "Chapter").prefix(512)),
        artworkUrl: safeURL((row["artworkUrl"] ?? row["img"] ?? row["image"]) as? String),
        url: safeURL((row["url"] ?? row["href"]) as? String))
    }.sorted { $0.startSeconds < $1.startSeconds }
  }
  public static func people(_ rows: [[String: Any]]) -> [PodcastPerson] {
    rows.prefix(100).compactMap { row in
      guard let raw = row["name"] as? String,
        !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
      let role = (row["role"] as? String) ?? "host"
      guard ["host", "co-host", "cohost"].contains(role.lowercased()) else { return nil }
      return PodcastPerson(name: String(raw.prefix(128)), role: role,
        imageUrl: safeURL((row["imageUrl"] ?? row["img"] ?? row["image"]) as? String),
        url: safeURL((row["url"] ?? row["href"]) as? String))
    }
  }
  public static func safeURL(_ raw: String?) -> String? {
    guard let raw, let value = URLComponents(string: raw), value.scheme?.lowercased() == "https",
      value.user == nil, value.password == nil, let host = value.host, !host.isEmpty else { return nil }
    return raw
  }
}
