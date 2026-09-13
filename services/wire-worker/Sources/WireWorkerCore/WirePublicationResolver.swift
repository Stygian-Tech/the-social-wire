import Foundation

actor WirePublicationResolver: WirePublicationResolving {
  private let store: any WirePublicationMetadataStoring
  private let queryClient: (any WirePublicationQuerying)?
  private let cache: (any WirePublicationCaching)?
  private let positiveCacheTTL: TimeInterval
  private let negativeCacheTTL: TimeInterval
  private let sharedNegativeCacheTTL: TimeInterval
  private let maximumNegativeCacheEntries: Int
  private var negativeCache: [String: Date] = [:]
  private struct Flight {
    let id: UUID
    let cacheToken: String?
    let task: Task<WirePublicationMetadata?, Error>
  }
  private var inFlight: [String: Flight] = [:]

  init(
    store: any WirePublicationMetadataStoring,
    queryClient: (any WirePublicationQuerying)?,
    cache: (any WirePublicationCaching)? = nil,
    positiveCacheTTL: TimeInterval = 60,
    negativeCacheTTL: TimeInterval = 600,
    sharedNegativeCacheTTL: TimeInterval = 15,
    maximumNegativeCacheEntries: Int = 512
  ) {
    self.store = store
    self.queryClient = queryClient
    self.cache = cache
    self.positiveCacheTTL = min(60, max(1, positiveCacheTTL))
    self.negativeCacheTTL = max(1, negativeCacheTTL)
    self.sharedNegativeCacheTTL = min(15, max(1, sharedNegativeCacheTTL))
    self.maximumNegativeCacheEntries = max(1, maximumNegativeCacheEntries)
  }

  func observe(_ metadata: WirePublicationMetadata, asOf: Date) async throws {
    await invalidate(publicationURI: metadata.publicationURI)
    do {
      try await store.upsert(metadata, asOf: asOf)
    } catch {
      await invalidate(publicationURI: metadata.publicationURI)
      throw error
    }
    await invalidate(publicationURI: metadata.publicationURI)
  }

  func resolve(publicationURI: String, asOf: Date) async throws -> WirePublicationMetadata? {
    guard let reference = WirePublicationReference.parse(publicationURI) else {
      throw WireStandardSiteDocumentError.malformedDocument
    }
    let initialLookup = try? await cache?.lookup(reference.uri, asOf: asOf)
    if let value = initialLookup?.value { return value.metadata }
    if let flight = inFlight[reference.uri], flight.cacheToken == initialLookup?.token {
      return try await flight.task.value
    }
    let rememberedMiss = negativeCache[reference.uri].map { $0 > asOf } ?? false
    let task = Task { [store, queryClient, cache, positiveCacheTTL, sharedNegativeCacheTTL] in
      var lookup = initialLookup
      var loaded = try await store.loadForCaching(publicationURI: reference.uri, asOf: asOf)
      // Without Redis, retain the old safety property: consult Postgres before
      // a local negative hit, so another replica's observation is visible.
      if loaded.metadata == nil, !rememberedMiss, let queryClient,
        let metadata = try await queryClient.query(publication: reference)
      {
        try? await cache?.invalidate(reference.uri)
        do {
          try await store.upsert(metadata, asOf: asOf)
        } catch {
          try? await cache?.invalidate(reference.uri)
          throw error
        }
        try? await cache?.invalidate(reference.uri)
        lookup = try? await cache?.lookup(reference.uri, asOf: asOf)
        // A newer event may have won the durable version fence. Cache only the
        // accepted row, never the upstream response we attempted to persist.
        loaded = try await store.loadForCaching(publicationURI: reference.uri, asOf: asOf)
      }
      if let token = lookup?.token {
        let ttl = loaded.metadata == nil ? sharedNegativeCacheTTL : positiveCacheTTL
        let value = WirePublicationCacheValue(metadata: loaded.metadata,
          expiresAt: min(loaded.expiresAt, asOf.addingTimeInterval(ttl)))
        try? await cache?.fill(reference.uri, token: token, value: value, asOf: asOf)
      }
      return loaded.metadata
    }
    let flightID = UUID()
    inFlight[reference.uri] = Flight(id: flightID, cacheToken: initialLookup?.token, task: task)
    defer {
      if inFlight[reference.uri]?.id == flightID { inFlight.removeValue(forKey: reference.uri) }
    }
    let metadata = try await task.value
    guard inFlight[reference.uri]?.id == flightID else { return metadata }
    if metadata == nil, !rememberedMiss {
      if negativeCache.count >= maximumNegativeCacheEntries { negativeCache.removeAll(keepingCapacity: true) }
      negativeCache[reference.uri] = asOf.addingTimeInterval(negativeCacheTTL)
    } else if metadata != nil {
      negativeCache.removeValue(forKey: reference.uri)
    }
    return metadata
  }

  func remove(publicationURI: String, observedAt: Date) async throws {
    guard let reference = WirePublicationReference.parse(publicationURI) else { return }
    await invalidate(publicationURI: reference.uri)
    do {
      try await store.remove(publicationURI: reference.uri, observedAt: observedAt)
    } catch {
      await invalidate(publicationURI: reference.uri)
      throw error
    }
    await invalidate(publicationURI: reference.uri)
  }

  func invalidateAccount(repoDID: String) async {
    inFlight = inFlight.filter { WirePublicationReference.parse($0.key)?.repoDID != repoDID }
    negativeCache = negativeCache.filter { WirePublicationReference.parse($0.key)?.repoDID != repoDID }
    try? await cache?.invalidateAccount(repoDID)
  }

  func invalidate(publicationURI: String) async {
    inFlight.removeValue(forKey: publicationURI)
    negativeCache.removeValue(forKey: publicationURI)
    try? await cache?.invalidate(publicationURI)
  }
}
