import Foundation

struct WirePublicationReference: Equatable, Sendable {
  let uri: String
  let repoDID: String
  let collection: String
  let recordKey: String

  static func parse(_ value: String) -> WirePublicationReference? {
    guard value.utf8.count <= 512, value.hasPrefix("at://") else { return nil }
    let components = value.dropFirst("at://".count).split(
      separator: "/", omittingEmptySubsequences: false)
    guard components.count == 3 else { return nil }
    let repoDID = canonicalRepoDID(String(components[0]))
    let collection = String(components[1])
    let recordKey = String(components[2])
    guard repoDID.hasPrefix("did:"), !recordKey.isEmpty,
      collection == "site.standard.publication" || collection == "com.standard.publication"
    else { return nil }
    return WirePublicationReference(
      uri: "at://\(repoDID)/\(collection)/\(recordKey)",
      repoDID: repoDID,
      collection: collection,
      recordKey: recordKey
    )
  }

  static func canonicalRepoDID(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.lowercased().hasPrefix("did:plc:") ? trimmed.lowercased() : trimmed
  }
}
