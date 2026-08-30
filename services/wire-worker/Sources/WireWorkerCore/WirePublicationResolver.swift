import Foundation

actor WirePublicationResolver: WirePublicationResolving {
  private struct NegativeCacheEntry: Sendable {
    let expiresAt: Date
  }

  private let store: any WirePublicationMetadataStoring
  private let queryClient: (any WirePublicationQuerying)?
  private let negativeCacheTTL: TimeInterval
  private let maximumNegativeCacheEntries: Int
  private var negativeCache: [String: NegativeCacheEntry] = [:]
  private var inFlight: [String: Task<WirePublicationMetadata?, Error>] = [:]

  init(
    store: any WirePublicationMetadataStoring,
    queryClient: (any WirePublicationQuerying)?,
    negativeCacheTTL: TimeInterval = 600,
    maximumNegativeCacheEntries: Int = 512
  ) {
    self.store = store
    self.queryClient = queryClient
    self.negativeCacheTTL = max(1, negativeCacheTTL)
    self.maximumNegativeCacheEntries = max(1, maximumNegativeCacheEntries)
  }

  func observe(_ metadata: WirePublicationMetadata, asOf: Date) async throws {
    try await store.upsert(metadata, asOf: asOf)
    negativeCache.removeValue(forKey: metadata.publicationURI)
  }

  func resolve(publicationURI: String, asOf: Date) async throws -> WirePublicationMetadata? {
    guard let reference = WirePublicationReference.parse(publicationURI) else {
      throw WireStandardSiteDocumentError.malformedDocument
    }
    if let metadata = try await store.load(publicationURI: reference.uri, asOf: asOf) {
      return metadata
    }
    if let cached = negativeCache[reference.uri], cached.expiresAt > asOf { return nil }
    negativeCache.removeValue(forKey: reference.uri)
    guard let queryClient else { return nil }
    if let task = inFlight[reference.uri] { return try await task.value }
    let task = Task<WirePublicationMetadata?, Error> { [store, queryClient] in
      guard let metadata = try await queryClient.query(publication: reference) else { return nil }
      try await store.upsert(metadata, asOf: asOf)
      return metadata
    }
    inFlight[reference.uri] = task
    defer { inFlight.removeValue(forKey: reference.uri) }
    guard let metadata = try await task.value else {
      rememberMiss(reference.uri, asOf: asOf)
      return nil
    }
    return metadata
  }

  func remove(publicationURI: String, observedAt: Date) async throws {
    guard let reference = WirePublicationReference.parse(publicationURI) else { return }
    try await store.remove(publicationURI: reference.uri, observedAt: observedAt)
    negativeCache.removeValue(forKey: reference.uri)
  }

  private func rememberMiss(_ publicationURI: String, asOf: Date) {
    if negativeCache.count >= maximumNegativeCacheEntries, negativeCache[publicationURI] == nil {
      negativeCache.removeAll(keepingCapacity: true)
    }
    negativeCache[publicationURI] = NegativeCacheEntry(
      expiresAt: asOf.addingTimeInterval(negativeCacheTTL)
    )
  }
}
