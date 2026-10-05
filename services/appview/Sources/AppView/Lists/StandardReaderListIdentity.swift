import Foundation

struct StandardReaderListIdentity: Sendable, Equatable {
  static let collection = "app.standard-reader.list"
  static let saveCollection = "app.standard-reader.listSave"
  let did: String
  let rkey: String
  var uri: String { "at://\(did)/\(Self.collection)/\(rkey)" }

  // Official share links use /l/{did}/{rkey}; view queries and anchors do not
  // change the record identity. Parse locally instead of fetching pasted URLs.
  static func parseResolutionInput(_ input: String) -> Self? {
    if let identity = parse(input) { return identity }
    let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URLComponents(string: raw), url.scheme == "https",
      url.host == "standard-reader.app", url.user == nil, url.password == nil,
      url.port == nil else { return nil }
    let parts = url.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 4, parts[0].isEmpty, parts[1] == "l",
      let did = String(parts[2]).removingPercentEncoding,
      let rkey = String(parts[3]).removingPercentEncoding else { return nil }
    return parse("at://\(did)/\(collection)/\(rkey)")
  }

  static func parse(_ input: String) -> Self? {
    let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard raw.hasPrefix("at://") else { return nil }
    let parts = raw.dropFirst(5).split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0].hasPrefix("did:"), parts[0].split(separator: ":").count >= 3, parts[0].count <= 2048, parts[1] == Substring(collection),
      !parts[2].isEmpty, parts[2].count <= 512, parts[2] != ".", parts[2] != "..",
      parts[0].allSatisfy({ $0.isASCII && !$0.isWhitespace && $0 != "?" && $0 != "#" }),
      parts[2].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._~:-".contains($0)) })
    else { return nil }
    return Self(did: String(parts[0]), rkey: String(parts[2]))
  }
}
