protocol WireBlobURLResolving: Sendable {
  func resolveBlobURL(repoDID: String, cid: String) async throws -> String?
}
