import Foundation

enum WirePostLinkExtractor {
  static func externalURL(in record: [String: Any]) -> String? {
    let embed = record["embed"] as? [String: Any]
    let media = embed?["media"] as? [String: Any]
    // The external card identifies the shared article; facet links can point
    // elsewhere. recordWithMedia keeps that card under its media member.
    for card in [embed?["external"], media?["external"]] {
      guard let card = card as? [String: Any] else { continue }
      for key in ["uri", "url"] {
        if let value = card[key] as? String, isHTTPURL(value) { return value }
      }
    }
    return firstStructuredURL(in: record)
  }

  private static func firstStructuredURL(in value: Any) -> String? {
    if let dictionary = value as? [String: Any] {
      // Keep support for legacy/nested uri and url fields, but never let
      // Dictionary hash ordering choose the article during replay.
      for key in dictionary.keys.sorted() {
        guard let child = dictionary[key] else { continue }
        if key == "uri" || key == "url", let string = child as? String,
          isHTTPURL(string)
        {
          return string
        }
        if let result = firstStructuredURL(in: child) { return result }
      }
    } else if let array = value as? [Any] {
      for child in array {
        if let result = firstStructuredURL(in: child) { return result }
      }
    }
    return nil
  }

  private static func isHTTPURL(_ value: String) -> Bool {
    guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else {
      return false
    }
    return (scheme == "http" || scheme == "https") && url.host != nil
  }
}
