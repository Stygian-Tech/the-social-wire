import Foundation
import Testing

@testable import WireWorkerCore

@Suite("Shared publication metadata cache")
struct WirePublicationSharedCacheTests {
  private let uri = "at://did:plc:author/site.standard.publication/main"
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  private var metadata: WirePublicationMetadata {
    .init(publicationURI: uri, repoDID: "did:plc:author", siteURL: "https://publisher.example", name: "Publisher")
  }

  @Test("positive and negative hits are shared across replicas without database reads")
  func sharedHits() async throws {
    for found in [true, false] {
      let store = PublicationCacheTestStore(value: found ? metadata : nil)
      let cache = PublicationCacheTestDouble()
      let first = WirePublicationResolver(store: store, queryClient: nil, cache: cache)
      let second = WirePublicationResolver(store: store, queryClient: nil, cache: cache)
      #expect(try await first.resolve(publicationURI: uri, asOf: now) == (found ? metadata : nil))
      #expect(try await second.resolve(publicationURI: uri, asOf: now) == (found ? metadata : nil))
      #expect(await store.loadCount == 1)
    }
  }

  @Test("hard TTL and authoritative source expiry both bound positive hits")
  func expiry() async throws {
    let store = PublicationCacheTestStore(value: metadata, expiresAt: now.addingTimeInterval(10))
    let resolver = WirePublicationResolver(store: store, queryClient: nil, cache: PublicationCacheTestDouble())
    #expect(try await resolver.resolve(publicationURI: uri, asOf: now) == metadata)
    #expect(try await resolver.resolve(publicationURI: uri, asOf: now.addingTimeInterval(9)) == metadata)
    #expect(await store.loadCount == 1)
    #expect(try await resolver.resolve(publicationURI: uri, asOf: now.addingTimeInterval(10)) == nil)
    #expect(await store.loadCount == 2)
  }

  @Test("new observations clear remote negative hits and deletes clear positive hits")
  func invalidation() async throws {
    let store = PublicationCacheTestStore(value: nil)
    let cache = PublicationCacheTestDouble()
    let first = WirePublicationResolver(store: store, queryClient: nil, cache: cache)
    let second = WirePublicationResolver(store: store, queryClient: nil, cache: cache)
    #expect(try await first.resolve(publicationURI: uri, asOf: now) == nil)
    try await second.observe(metadata, asOf: now)
    #expect(try await first.resolve(publicationURI: uri, asOf: now) == metadata)
    try await second.remove(publicationURI: uri, observedAt: now)
    #expect(try await first.resolve(publicationURI: uri, asOf: now) == nil)
  }

  @Test("Redis failures do not prevent durable reads or mutations")
  func outage() async throws {
    let store = PublicationCacheTestStore(value: nil)
    let resolver = WirePublicationResolver(store: store, queryClient: nil,
      cache: PublicationCacheTestDouble(unavailable: true))
    try await resolver.observe(metadata, asOf: now)
    #expect(try await resolver.resolve(publicationURI: uri, asOf: now) == metadata)
    try await resolver.remove(publicationURI: uri, observedAt: now)
    #expect(try await resolver.resolve(publicationURI: uri, asOf: now) == nil)
  }

  @Test("in-flight reads cannot refill an invalidated shared key", arguments: [true, false])
  func staleFill(observe: Bool) async throws {
    let store = PublicationCacheTestStore(value: metadata, pausesFirstLoad: true)
    let cache = PublicationCacheTestDouble()
    let first = WirePublicationResolver(store: store, queryClient: nil, cache: cache)
    let second = WirePublicationResolver(store: store, queryClient: nil, cache: cache)
    let oldRead = Task { try await first.resolve(publicationURI: uri, asOf: now) }
    await store.waitUntilPaused()
    let replacement = observe ? WirePublicationMetadata(publicationURI: uri, repoDID: metadata.repoDID,
      siteURL: metadata.siteURL, name: "Updated") : nil
    if let replacement {
      try await second.observe(replacement, asOf: now)
    } else {
      try await second.remove(publicationURI: uri, observedAt: now)
    }
    // This request is on the replica still holding the paused old flight. It
    // must observe the new epoch rather than join that older request.
    #expect(try await first.resolve(publicationURI: uri, asOf: now) == replacement)
    await store.resumeLoad()
    _ = try await oldRead.value
    #expect(try await second.resolve(publicationURI: uri, asOf: now) == replacement)
    #expect(await cache.rejectedFills == 1)
  }

  @Test("local simultaneous readers share the database load")
  func coalescesDatabaseLoad() async throws {
    let store = PublicationCacheTestStore(value: metadata, pausesFirstLoad: true)
    let resolver = WirePublicationResolver(store: store, queryClient: nil, cache: PublicationCacheTestDouble())
    let first = Task { try await resolver.resolve(publicationURI: uri, asOf: now) }
    await store.waitUntilPaused()
    let second = Task { try await resolver.resolve(publicationURI: uri, asOf: now) }
    await store.resumeLoad()
    #expect(try await first.value == metadata)
    #expect(try await second.value == metadata)
    #expect(await store.loadCount == 1)
  }

  @Test("negative cache expires after fifteen seconds")
  func negativeExpiry() async throws {
    let store = PublicationCacheTestStore(value: nil)
    let resolver = WirePublicationResolver(store: store, queryClient: nil, cache: PublicationCacheTestDouble())
    _ = try await resolver.resolve(publicationURI: uri, asOf: now)
    _ = try await resolver.resolve(publicationURI: uri, asOf: now.addingTimeInterval(14))
    #expect(await store.loadCount == 1)
    _ = try await resolver.resolve(publicationURI: uri, asOf: now.addingTimeInterval(15))
    #expect(await store.loadCount == 2)
  }
}

private actor PublicationCacheTestStore: WirePublicationMetadataStoring {
  var value: WirePublicationMetadata?
  let expiresAt: Date
  let pausesFirstLoad: Bool
  private(set) var loadCount = 0
  private var resume: CheckedContinuation<Void, Never>?
  private var waiting: CheckedContinuation<Void, Never>?

  init(value: WirePublicationMetadata?, expiresAt: Date = .distantFuture, pausesFirstLoad: Bool = false) {
    self.value = value
    self.expiresAt = expiresAt
    self.pausesFirstLoad = pausesFirstLoad
  }

  func load(publicationURI: String, asOf: Date) async -> WirePublicationMetadata? {
    await loadForCaching(publicationURI: publicationURI, asOf: asOf).metadata
  }

  func loadForCaching(publicationURI: String, asOf: Date) async -> WirePublicationCacheValue {
    loadCount += 1
    let captured = value
    if pausesFirstLoad, loadCount == 1 {
      await withCheckedContinuation { continuation in
        resume = continuation
        waiting?.resume()
        waiting = nil
      }
    }
    return .init(metadata: expiresAt > asOf ? captured : nil, expiresAt: expiresAt)
  }

  func waitUntilPaused() async {
    if resume != nil { return }
    await withCheckedContinuation { waiting = $0 }
  }

  func resumeLoad() {
    resume?.resume()
    resume = nil
  }

  func upsert(_ metadata: WirePublicationMetadata, asOf: Date) { value = metadata }
  func remove(publicationURI: String, observedAt: Date) { value = nil }
}

private actor PublicationCacheTestDouble: WirePublicationCaching {
  private var epoch = UUID().uuidString
  private var values: [String: WirePublicationCacheValue] = [:]
  private let unavailable: Bool
  private(set) var rejectedFills = 0
  private enum Failure: Error { case unavailable }

  init(unavailable: Bool = false) { self.unavailable = unavailable }

  func lookup(_ uri: String, asOf: Date) throws -> WirePublicationCacheLookup {
    if unavailable { throw Failure.unavailable }
    return .init(token: epoch, value: values[uri].flatMap { $0.expiresAt > asOf ? $0 : nil })
  }

  func fill(_ uri: String, token: String, value: WirePublicationCacheValue, asOf: Date) throws {
    if unavailable { throw Failure.unavailable }
    guard token == epoch else { rejectedFills += 1; return }
    values[uri] = value
  }

  func invalidate(_ uri: String) throws {
    if unavailable { throw Failure.unavailable }
    epoch = UUID().uuidString
    values.removeAll()
  }

  func invalidateAccount(_ repoDID: String) throws { try invalidate(repoDID) }
}
