enum WirePublicationQueryError: Error, Equatable, Sendable {
  case invalidDID
  case unsafeEndpoint
  case dnsUnavailable
  case transientStatus(UInt)
  case responseTooLarge
  case invalidResponse
}
