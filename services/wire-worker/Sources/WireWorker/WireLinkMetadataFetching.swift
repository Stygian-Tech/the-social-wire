protocol WireLinkMetadataFetching: Sendable {
  func fetch(_ target: WireLinkMetadataTarget) async throws -> WireLinkMetadataFetchResult
}
