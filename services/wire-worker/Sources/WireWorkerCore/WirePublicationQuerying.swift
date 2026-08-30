protocol WirePublicationQuerying: Sendable {
  func query(publication: WirePublicationReference) async throws -> WirePublicationMetadata?
}
