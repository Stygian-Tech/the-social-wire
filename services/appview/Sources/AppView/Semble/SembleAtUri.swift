import Foundation

struct SembleAtUri: Equatable, Sendable {
  let did: String
  let collection: String
  let rkey: String

  static func parse(_ raw: String) -> SembleAtUri? {
    guard raw.hasPrefix("at://") else { return nil }
    let components = raw.dropFirst(5).split(separator: "/", omittingEmptySubsequences: false)
    guard components.count == 3 else { return nil }
    let did = String(components[0])
    let collection = String(components[1])
    let rkey = String(components[2])
    guard did.hasPrefix("did:"), !collection.isEmpty, !rkey.isEmpty else { return nil }
    return SembleAtUri(did: did, collection: collection, rkey: rkey)
  }
}

enum SembleCursor {
  private struct Payload: Codable { let page: Int }

  static func encode(nextPage: Int?) -> String? {
    guard let nextPage else { return nil }
    guard let data = try? JSONEncoder().encode(Payload(page: nextPage)) else { return nil }
    return data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  static func decode(_ raw: String?) -> Int? {
    guard let raw else { return 1 }
    guard !raw.isEmpty else { return nil }
    var base64 = raw.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let padding = (4 - base64.count % 4) % 4
    base64.append(String(repeating: "=", count: padding))
    guard let data = Data(base64Encoded: base64),
      let payload = try? JSONDecoder().decode(Payload.self, from: data),
      payload.page > 0
    else { return nil }
    return payload.page
  }
}
