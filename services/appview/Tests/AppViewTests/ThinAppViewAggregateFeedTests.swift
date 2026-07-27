import Foundation
import GatewayCore
import Logging
import Testing
import ThinAppViewCore

@testable import AppView

@Suite("Thin AppView aggregate feeds")
struct ThinAppViewAggregateFeedTests {
  @Test("globally orders member publications and emits publication identity")
  func globalOrderingAndPublicationIdentity() async throws {
    let logger = Logger(label: "aggregate-feed.test")
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("aggregate-feed-\(UUID().uuidString).sqlite")
      .path
    defer { try? FileManager.default.removeItem(atPath: path) }

    let store = try SQLiteThinAppViewStore(path: path, logger: logger)
    let service = ThinAppViewReadService(store: store, logger: logger)
    let first = publication(id: "at://did:plc:first/site.standard.publication/main")
    let second = publication(id: "at://did:plc:second/site.standard.publication/main")
    try await store.upsertContentItem(
      item(
        uri: "at://did:plc:first/site.standard.document/older",
        authorDid: first.authorDid,
        publicationId: first.publicationId,
        publishedAt: Date(timeIntervalSince1970: 100)
      )
    )
    try await store.upsertContentItem(
      item(
        uri: "at://did:plc:second/site.standard.document/newer",
        authorDid: second.authorDid,
        publicationId: second.publicationId,
        publishedAt: Date(timeIntervalSince1970: 200)
      )
    )

    let page = try await service.listFeed(
      auth: AuthContext(
        did: "did:plc:viewer",
        authorizationForwardingValue: "DPoP token",
        dpopProof: "proof"
      ),
      publications: [first, second],
      filter: .all,
      cursor: nil,
      limit: 50
    )

    #expect(page.entries.map(\.entryId) == [
      "at://did:plc:second/site.standard.document/newer",
      "at://did:plc:first/site.standard.document/older",
    ])
    #expect(page.entries.map(\.publicationId) == [
      second.publicationId,
      first.publicationId,
    ])
  }

  private func publication(id: String) -> SidebarPublicationRow {
    let authorDid = String(id.split(separator: "/")[2])
    return SidebarPublicationRow(
      publicationId: id,
      subscriptionPublicationId: nil,
      authorDid: authorDid,
      authorHandle: nil,
      title: id,
      iconUrl: nil,
      avatarUrl: nil,
      discoveredAt: Date(),
      appViewScope: PublicationAppViewScope(
        authorDid: authorDid,
        publicationAtUri: id,
        publicationScopeAtUris: [id],
        publicationSiteUrls: []
      )
    )
  }

  private func item(
    uri: String,
    authorDid: String,
    publicationId: String,
    publishedAt: Date
  ) -> IndexedContentItem {
    IndexedContentItem(
      uri: uri,
      cid: uri,
      authorDid: authorDid,
      collection: "site.standard.document",
      createdAt: publishedAt,
      indexedAt: publishedAt,
      publicationSite: publicationId,
      render: ContentRenderFields(
        title: uri,
        publishedAt: ISO8601DateFormatter().string(from: publishedAt),
        articleUrl: "https://example.com/\(uri.split(separator: "/").last!)"
      ),
      expiresAt: .distantFuture
    )
  }
}
