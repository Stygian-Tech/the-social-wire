struct PDSReadStateConfirmRequest: Decodable, Sendable {
  let manifestCid: String
  let expectedLegacyRevision: Int64?
}
