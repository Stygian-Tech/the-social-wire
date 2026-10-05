import Foundation

/// Public RSS sources only. Opaque credentials in URL paths cannot be classified reliably.
public enum PodcastRSSURL {
  public static func isAllowed(_ raw: String) -> Bool {
    guard
      let components = URLComponents(
        string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
      components.scheme?.lowercased() == "https",
      let host = components.host, !host.isEmpty,
      components.user == nil, components.password == nil,
      components.url != nil
    else { return false }
    let allowed = Set(["feed", "format"])
    let publicFormats = Set(["rss", "rss2", "atom", "rdf", "xml"])
    return (components.queryItems ?? []).allSatisfy {
      allowed.contains($0.name.lowercased())
        && publicFormats.contains(($0.value ?? "").lowercased())
    }
  }
}
