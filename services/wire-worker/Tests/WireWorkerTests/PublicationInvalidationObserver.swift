import Foundation

@testable import WireWorkerCore

actor PublicationInvalidationObserver: WirePublicationResolving {
  let store: any WirePublicationMetadataStoring
  private(set) var observedNames: [String?] = []

  init(store: any WirePublicationMetadataStoring) { self.store = store }

  func invalidate(publicationURI: String) async {
    let value = try? await store.load(publicationURI: publicationURI, asOf: Date())
    observedNames.append(value?.name)
  }

  func observe(_ metadata: WirePublicationMetadata, asOf: Date) async throws {
    try await store.upsert(metadata, asOf: asOf)
  }

  func resolve(publicationURI: String, asOf: Date) async throws -> WirePublicationMetadata? {
    try await store.load(publicationURI: publicationURI, asOf: asOf)
  }

  func remove(publicationURI: String, observedAt: Date) async throws {
    try await store.remove(publicationURI: publicationURI, observedAt: observedAt)
  }
}
