struct WireEditionModuleRecord: Encodable, Sendable {
  let moduleKey: String
  let moduleKind: String
  let title: String?
  let position: Int
  let reasonCode: String?
  let publicationKey: String?
  let publicationName: String?
  let publicationDomain: String?
  let publicationHomepageUrl: String?
  let publicationIconUrl: String?
}
