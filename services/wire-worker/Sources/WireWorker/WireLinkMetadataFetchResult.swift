enum WireLinkMetadataFetchResult: Equatable, Sendable {
  case notModified(etag: String?, lastModified: String?)
  case metadata(WireLinkMetadata)
}
