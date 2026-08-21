struct WireLabelQueryPage: Equatable, Sendable {
  let cursor: String?
  let labels: [WireLabelQueryRecord]
}

struct WireLabelQueryRecord: Equatable, Sendable {
  let sourceDID: String
  let subjectURI: String
  let value: String
  let negated: Bool
  let createdAt: String
  let expiresAt: String?
}
