import Foundation

struct WireResolvedStandardSiteDocument: Equatable, Sendable {
  let canonicalURL: String
  let publicationURI: String?
  let publicationName: String?
}
