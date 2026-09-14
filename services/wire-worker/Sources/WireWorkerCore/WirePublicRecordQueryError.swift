enum WirePublicRecordQueryError: Error, Equatable {
  case invalidReference
  case unsafeEndpoint
  case invalidResponse
  case responseTooLarge
  case redirected
  case repositoryChanged
  case transientStatus(Int)
  case unavailable
}
