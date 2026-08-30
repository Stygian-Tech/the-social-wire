import Foundation

struct WirePublicationMetadata: Equatable, Sendable {
  let publicationURI: String
  let repoDID: String
  let siteURL: String
  let name: String

  static func parse(
    publicationURI: String,
    repoDID: String,
    record: [String: Any]
  ) -> WirePublicationMetadata? {
    guard let reference = WirePublicationReference.parse(publicationURI),
      reference.repoDID == WirePublicationReference.canonicalRepoDID(repoDID),
      let siteURL = WireStandardSiteURL.publicationBase(from: record)
    else { return nil }
    let name =
      firstString(record, keys: ["name", "title"]) ?? URL(string: siteURL)?.host ?? siteURL
    return WirePublicationMetadata(
      publicationURI: reference.uri,
      repoDID: reference.repoDID,
      siteURL: siteURL,
      name: String(name.prefix(500))
    )
  }

  private static func firstString(_ record: [String: Any], keys: [String]) -> String? {
    for key in keys {
      if let value = record[key] as? String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
      }
    }
    return nil
  }
}
