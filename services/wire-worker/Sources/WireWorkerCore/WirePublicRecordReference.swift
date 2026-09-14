import Foundation

struct WirePublicRecordReference: Sendable {
  let uri: String
  let repoDID: String
  let collection: String
  let recordKey: String

  init(_ uri: String) throws {
    let parts = uri.dropFirst(5).split(separator: "/", omittingEmptySubsequences: false)
    guard uri.hasPrefix("at://"), uri.utf8.count <= 2_048, parts.count == 3,
      ["site.standard.graph.recommend", "site.standard.document", "site.standard.entry",
       "site.standard.publication"].contains(String(parts[1])),
      !parts[2].isEmpty, parts[2].count <= 512, parts[2] != ".", parts[2] != "..",
      parts[2].utf8.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
          || "._~:-".utf8.contains($0)
      })
    else { throw WirePublicRecordQueryError.invalidReference }
    self.uri = uri
    repoDID = String(parts[0])
    collection = String(parts[1])
    recordKey = String(parts[2])
    _ = try didDocumentURL()
  }

  func didDocumentURL() throws -> URL {
    if repoDID.hasPrefix("did:plc:") {
      let identifier = repoDID.dropFirst(8)
      guard identifier.count == 24,
        identifier.utf8.allSatisfy({ "abcdefghijklmnopqrstuvwxyz234567".utf8.contains($0) }),
        let url = URL(string: "https://plc.directory/\(repoDID)")
      else { throw WirePublicRecordQueryError.invalidReference }
      return url
    }
    guard repoDID.hasPrefix("did:web:") else { throw WirePublicRecordQueryError.invalidReference }
    let parts = repoDID.dropFirst(8).split(separator: ":", omittingEmptySubsequences: false)
    guard let first = parts.first, let host = String(first).removingPercentEncoding,
      WirePublicEndpointValidator.isPublicHostname(host.lowercased())
    else { throw WirePublicRecordQueryError.invalidReference }
    let paths = parts.dropFirst().compactMap { String($0).removingPercentEncoding }
    guard paths.count == parts.count - 1,
      paths.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\\") })
    else { throw WirePublicRecordQueryError.invalidReference }
    var url = URLComponents()
    url.scheme = "https"
    url.host = host.lowercased()
    url.path = paths.isEmpty ? "/.well-known/did.json" : "/\(paths.joined(separator: "/"))/did.json"
    guard let result = url.url else { throw WirePublicRecordQueryError.invalidReference }
    return result
  }

  /// AT Protocol records use CIDv1, dag-cbor and a SHA-256 multihash in base32.
  static func validCID(_ cid: String) -> Bool {
    guard cid.count == 59, cid.first == "b" else { return false }
    let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567".utf8)
    var buffer: UInt16 = 0
    var bits = 0
    var bytes: [UInt8] = []
    for character in cid.utf8.dropFirst() {
      guard let value = alphabet.firstIndex(of: character) else { return false }
      buffer = (buffer << 5) | UInt16(value)
      bits += 5
      if bits >= 8 {
        bits -= 8
        bytes.append(UInt8((buffer >> bits) & 255))
        buffer &= (1 << bits) - 1
      }
    }
    return bytes.count == 36 && bytes.prefix(4).elementsEqual([1, 0x71, 0x12, 0x20]) && buffer == 0
  }
}
