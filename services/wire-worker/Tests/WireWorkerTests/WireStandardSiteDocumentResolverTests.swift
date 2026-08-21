import Foundation
import Testing

@testable import WireWorker

@Suite("Standard Site document resolution")
struct WireStandardSiteDocumentResolverTests {
  @Test("resolves the real site AT-URI plus path schema")
  func resolvesRealSchema() async throws {
    let publication = try fixture("site-standard-publication")
    let document = try fixture("site-standard-document")
    let store = InMemoryWirePublicationStore()
    let resolver = WirePublicationResolver(store: store, queryClient: nil)
    let metadata = try #require(
      WirePublicationMetadata.parse(
        publicationURI: "at://did:plc:author/site.standard.publication/main",
        repoDID: "did:plc:author",
        record: publication
      ))
    try await resolver.observe(metadata, asOf: Date(timeIntervalSince1970: 1_700_000_000))

    let resolved = try await WireStandardSiteDocumentResolver.resolve(
      record: document,
      publicationResolver: resolver,
      asOf: Date(timeIntervalSince1970: 1_700_000_001)
    )
    #expect(resolved.canonicalURL == "https://publication.example/stories/the-wire-fixture")
    #expect(resolved.publicationURI == "at://did:plc:author/site.standard.publication/main")
    #expect(resolved.publicationName == "Example Standard Site")
  }

  @Test("resolves an HTTPS publication site plus relative path without a network lookup")
  func resolvesHTTPSPublicationSite() async throws {
    let query = StubWirePublicationQuery(result: nil)
    let resolved = try await WireStandardSiteDocumentResolver.resolve(
      record: ["site": "https://publisher.example/", "path": "/articles/example"],
      publicationResolver: WirePublicationResolver(
        store: InMemoryWirePublicationStore(), queryClient: query
      ),
      asOf: Date()
    )
    #expect(resolved.canonicalURL == "https://publisher.example/articles/example")
    #expect(await query.queryCount == 0)
  }

  @Test("an unresolved publication remains distinguishable from malformed input")
  func unresolvedPublication() async throws {
    let document = try fixture("site-standard-document")
    let resolver = WirePublicationResolver(
      store: InMemoryWirePublicationStore(),
      queryClient: StubWirePublicationQuery(result: nil)
    )
    await #expect(throws: WireStandardSiteDocumentError.unresolvedPublication) {
      try await WireStandardSiteDocumentResolver.resolve(
        record: document,
        publicationResolver: resolver,
        asOf: Date(timeIntervalSince1970: 1_700_000_000)
      )
    }
  }

  @Test("direct canonical URLs remain backward compatible")
  func directURL() async throws {
    let resolved = try await WireStandardSiteDocumentResolver.resolve(
      record: ["canonicalUrl": "http://publisher.example/story#fragment"],
      publicationResolver: WirePublicationResolver(
        store: InMemoryWirePublicationStore(), queryClient: nil
      ),
      asOf: Date()
    )
    #expect(resolved.canonicalURL == "https://publisher.example/story")
  }

  private func fixture(_ name: String) throws -> [String: Any] {
    let url = try #require(
      Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
    )
    let data = try Data(contentsOf: url)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }
}

actor InMemoryWirePublicationStore: WirePublicationMetadataStoring {
  private var values: [String: WirePublicationMetadata] = [:]
  private(set) var upsertCount = 0

  func load(publicationURI: String, asOf: Date) -> WirePublicationMetadata? {
    values[publicationURI]
  }

  func upsert(_ metadata: WirePublicationMetadata, asOf: Date) {
    values[metadata.publicationURI] = metadata
    upsertCount += 1
  }

  func remove(publicationURI: String, observedAt: Date) {
    values.removeValue(forKey: publicationURI)
  }
}

actor StubWirePublicationQuery: WirePublicationQuerying {
  let result: WirePublicationMetadata?
  let delayNanoseconds: UInt64
  private(set) var queryCount = 0

  init(result: WirePublicationMetadata?, delayNanoseconds: UInt64 = 0) {
    self.result = result
    self.delayNanoseconds = delayNanoseconds
  }

  func query(publication: WirePublicationReference) async throws -> WirePublicationMetadata? {
    queryCount += 1
    if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
    return result
  }
}
