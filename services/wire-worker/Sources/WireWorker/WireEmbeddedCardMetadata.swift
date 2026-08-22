import Foundation
import WireCore

enum WireEmbeddedCardMetadata {
  static func extract(from record: [String: Any], canonicalURL: String) -> WireLinkMetadata? {
    guard let external = findExternal(in: record["embed"]) else { return nil }
    let rawURL = string(external["uri"]) ?? string(external["url"])
    guard let rawURL, let identity = WireCanonicalizer.canonicalize(rawURL),
      identity.canonicalURL == canonicalURL
    else { return nil }
    let title = trimmed(string(external["title"]))
    let description = trimmed(string(external["description"]))
    let imageURL = publicHTTPURL(string(external["thumb"]) ?? string(external["image"]))
    guard title != nil || description != nil || imageURL != nil else { return nil }
    return WireLinkMetadata(
      canonicalURL: canonicalURL,
      title: title,
      description: description,
      imageURL: imageURL,
      siteName: nil,
      iconURL: nil,
      etag: nil,
      lastModified: nil,
      source: .embeddedCard
    )
  }

  private static func findExternal(in value: Any?) -> [String: Any]? {
    if let dictionary = value as? [String: Any] {
      if let external = dictionary["external"] as? [String: Any] { return external }
      for child in dictionary.values {
        if let external = findExternal(in: child) { return external }
      }
    } else if let array = value as? [Any] {
      for child in array {
        if let external = findExternal(in: child) { return external }
      }
    }
    return nil
  }

  private static func string(_ value: Any?) -> String? {
    value as? String
  }

  private static func trimmed(_ value: String?) -> String? {
    guard let value else { return nil }
    let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return result.isEmpty ? nil : String(result.prefix(2_000))
  }

  private static func publicHTTPURL(_ value: String?) -> String? {
    guard let value = trimmed(value), let url = URL(string: value),
      let scheme = url.scheme?.lowercased(), (scheme == "http" || scheme == "https"),
      url.host != nil
    else { return nil }
    return url.absoluteString
  }
}
