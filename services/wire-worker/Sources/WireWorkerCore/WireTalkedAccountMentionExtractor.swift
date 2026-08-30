import Foundation

enum WireTalkedAccountMentionExtractor {
  static func subjects(in record: [String: Any]) -> [String] {
    var result = Set<String>()
    if let facets = record["facets"] as? [[String: Any]] {
      for facet in facets {
        guard let features = facet["features"] as? [[String: Any]] else { continue }
        for feature in features {
          guard (feature["$type"] as? String) == "app.bsky.richtext.facet#mention",
            let did = normalizedDID(feature["did"] as? String)
          else { continue }
          result.insert(did)
        }
      }
    }
    collectQuotedSubjects(record["embed"], into: &result)
    return result.sorted()
  }

  private static func collectQuotedSubjects(_ value: Any?, into result: inout Set<String>) {
    if let dictionary = value as? [String: Any] {
      if let uri = dictionary["uri"] as? String, let did = didFromATURI(uri) {
        result.insert(did)
      }
      for child in dictionary.values { collectQuotedSubjects(child, into: &result) }
    } else if let array = value as? [Any] {
      for child in array { collectQuotedSubjects(child, into: &result) }
    }
  }

  private static func didFromATURI(_ value: String) -> String? {
    guard value.hasPrefix("at://") else { return nil }
    let suffix = value.dropFirst("at://".count)
    guard let authority = suffix.split(separator: "/", maxSplits: 1).first else { return nil }
    return normalizedDID(String(authority))
  }

  private static func normalizedDID(_ value: String?) -> String? {
    guard let value else { return nil }
    let result = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard result.hasPrefix("did:"), result.count <= 2_048,
      !result.contains(where: { $0.isWhitespace })
    else { return nil }
    return result
  }
}
