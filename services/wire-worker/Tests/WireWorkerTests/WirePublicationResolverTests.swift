import Foundation
import Testing

@testable import WireWorkerCore

@Suite("Wire publication resolver")
struct WirePublicationResolverTests {
  @Test("canonicalizes did:plc publication references")
  func canonicalizesPLCDID() throws {
    let reference = try #require(
      WirePublicationReference.parse(
        "at://DID:PLC:AUTHOR/site.standard.publication/main"
      )
    )
    #expect(reference.repoDID == "did:plc:author")
    #expect(
      reference.uri == "at://did:plc:author/site.standard.publication/main"
    )
  }

  @Test("a PDS result is durably cached and reused")
  func cachesQueryResult() async throws {
    let metadata = WirePublicationMetadata(
      publicationURI: "at://did:plc:author/site.standard.publication/main",
      repoDID: "did:plc:author",
      siteURL: "https://publisher.example",
      name: "Publisher"
    )
    let store = InMemoryWirePublicationStore()
    let query = StubWirePublicationQuery(result: metadata)
    let resolver = WirePublicationResolver(store: store, queryClient: query)
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    #expect(
      try await resolver.resolve(publicationURI: metadata.publicationURI, asOf: now) == metadata)
    #expect(
      try await resolver.resolve(publicationURI: metadata.publicationURI, asOf: now) == metadata)
    #expect(await query.queryCount == 1)
    #expect(await store.upsertCount == 1)
  }

  @Test("negative results are bounded by a short cache")
  func negativeCache() async throws {
    let query = StubWirePublicationQuery(result: nil)
    let resolver = WirePublicationResolver(
      store: InMemoryWirePublicationStore(),
      queryClient: query,
      negativeCacheTTL: 60
    )
    let uri = "at://did:plc:author/site.standard.publication/main"
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    #expect(try await resolver.resolve(publicationURI: uri, asOf: now) == nil)
    #expect(
      try await resolver.resolve(publicationURI: uri, asOf: now.addingTimeInterval(59)) == nil)
    #expect(await query.queryCount == 1)
    #expect(
      try await resolver.resolve(publicationURI: uri, asOf: now.addingTimeInterval(61)) == nil)
    #expect(await query.queryCount == 2)
  }

  @Test("observing the same publication is idempotent at the durable key")
  func idempotentObservation() async throws {
    let record: [String: Any] = ["name": "Publisher", "url": "https://publisher.example/"]
    let store = InMemoryWirePublicationStore()
    let resolver = WirePublicationResolver(store: store, queryClient: nil)
    let uri = "at://did:plc:author/site.standard.publication/main"
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let metadata = try #require(
      WirePublicationMetadata.parse(
        publicationURI: uri, repoDID: "did:plc:author", record: record
      ))
    try await resolver.observe(metadata, asOf: now)
    try await resolver.observe(metadata, asOf: now)
    #expect(try await resolver.resolve(publicationURI: uri, asOf: now) != nil)
    #expect(await store.upsertCount == 2)
  }

  @Test("concurrent misses coalesce into one bounded upstream query")
  func coalescesConcurrentQueries() async throws {
    let metadata = WirePublicationMetadata(
      publicationURI: "at://did:plc:author/site.standard.publication/main",
      repoDID: "did:plc:author",
      siteURL: "https://publisher.example",
      name: "Publisher"
    )
    let query = StubWirePublicationQuery(result: metadata, delayNanoseconds: 10_000_000)
    let resolver = WirePublicationResolver(
      store: InMemoryWirePublicationStore(), queryClient: query
    )
    async let first = resolver.resolve(publicationURI: metadata.publicationURI, asOf: Date())
    async let second = resolver.resolve(publicationURI: metadata.publicationURI, asOf: Date())
    #expect(try await first == metadata)
    #expect(try await second == metadata)
    #expect(await query.queryCount == 1)
  }
}
