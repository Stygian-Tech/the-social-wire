import Foundation

enum WireStandardSiteURL {
  static func publicationBase(from record: [String: Any]) -> String? {
    for key in ["url", "siteUrl", "site", "homepage"] {
      guard let raw = record[key] as? String else { continue }
      if let normalized = normalizeHTTPS(raw, removeQuery: true) { return normalized }
    }
    return nil
  }

  static func articleURL(path: String, publicationBase: String) -> String? {
    if let absolute = normalizeHTTPS(path, removeQuery: false) { return absolute }
    guard let normalizedBase = normalizeHTTPS(publicationBase, removeQuery: true) else {
      return nil
    }
    let cleanPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !cleanPath.isEmpty else { return normalizedBase }
    return normalizeHTTPS("\(normalizedBase)/\(cleanPath)", removeQuery: false)
  }

  private static func normalizeHTTPS(_ raw: String, removeQuery: Bool) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard var components = URLComponents(string: trimmed),
      let scheme = components.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      let host = components.host, !host.isEmpty,
      components.user == nil, components.password == nil
    else { return nil }
    components.scheme = "https"
    components.fragment = nil
    if removeQuery { components.query = nil }
    guard var result = components.url?.absoluteString else { return nil }
    while result.hasSuffix("/") { result.removeLast() }
    return result
  }
}
