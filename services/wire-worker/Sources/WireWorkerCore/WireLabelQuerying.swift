protocol WireLabelQuerying: Sendable {
  func query(
    labeler: WireLabelerEndpoint,
    uriPatterns: [String],
    cursor: String?
  ) async throws -> WireLabelQueryPage
}
