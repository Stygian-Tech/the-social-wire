protocol WireCorpusTransport: Sendable {
  func get(target: String) async throws -> WireCorpusTransportResponse
}
