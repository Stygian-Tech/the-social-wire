enum WireLinkMetadataQueryError: Error, Equatable {
  case unsafeEndpoint
  case invalidResponse
  case unsupportedContentType
  case responseTooLarge
  case tooManyRedirects
  case transientStatus(Int)
}
