struct PDSReadStatePrepareRequest: Decodable, Sendable {
  let scope: ScopedMarkAllReadScope
  let before: String?
  let timeZone: String?
  let referenceDate: String?
  let previewSubjectUris: [String]?
}
