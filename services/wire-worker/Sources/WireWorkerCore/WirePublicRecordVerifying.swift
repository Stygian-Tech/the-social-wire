protocol WirePublicRecordVerifying: Sendable {
  func verify(uri: String, expectedCID: String?) async throws -> WirePublicRecordVerification
}
