import Foundation
import GatewayCore
import Logging
import Testing
import ThinAppViewCore

@testable import AppView

@Suite("Thin AppView aggregate feeds")
struct ThinAppViewAggregateFeedTests {
  @Test("subscribed performance metrics use only deidentified aggregate dimensions")
  func deidentifiedMetricDimensions() {
    let dimensions = ThinAppViewReadService.subscribedFeedMetricDimensions(
      pageKind: "pagination"
    )

    #expect(dimensions == [
      "feed_kind": "subscribed",
      "page_kind": "pagination",
    ])
  }

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

  @Test("subscribed feed uses materialized membership and database cursor positions")
  func subscribedMembershipAndStableCursor() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(atPath: fixture.path) }
    let first = publication(id: "at://did:plc:first/site.standard.publication/main")
    let second = publication(id: "at://did:plc:second/site.standard.publication/main")
    let sharedPosition = Date(timeIntervalSince1970: 500)
    let misleadingPublishedAt = Date(timeIntervalSince1970: 50_000)

    try await fixture.store.replacePublicationScopes(
      viewerDid: fixture.viewerDid,
      scopes: [
        subscribedScope(first),
        subscribedScope(second),
      ]
    )
    for (suffix, publication, renderedAt) in [
      ("a", first, misleadingPublishedAt),
      ("b", second, Date(timeIntervalSince1970: 1)),
      ("c", first, Date(timeIntervalSince1970: 2)),
    ] {
      try await fixture.store.upsertContentItem(
        item(
          uri: "at://\(publication.authorDid)/site.standard.document/\(suffix)",
          authorDid: publication.authorDid,
          publicationId: publication.publicationId,
          createdAt: sharedPosition,
          renderedPublishedAt: renderedAt
        )
      )
    }

    let firstPage = try #require(
      try await fixture.service.listSubscribedFeed(
        auth: fixture.auth,
        filter: .all,
        cursor: nil,
        limit: 2
      )
    )
    #expect(firstPage.entries.map(\.entryId).map { $0.split(separator: "/").last! } == ["c", "b"])
    let decodedCursor = try #require(firstPage.cursor.flatMap(ThinAppViewCursor.decode))
    #expect(decodedCursor.createdAt == sharedPosition)
    #expect(decodedCursor.uri.hasSuffix("/b"))

    let secondPage = try #require(
      try await fixture.service.listSubscribedFeed(
        auth: fixture.auth,
        filter: .all,
        cursor: firstPage.cursor,
        limit: 2
      )
    )
    #expect(secondPage.entries.map(\.entryId).map { $0.split(separator: "/").last! } == ["a"])
  }

  @Test("subscribed aggregate scan suppresses canonical duplicates and batches read state")
  func duplicateSuppressionAndReadState() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(atPath: fixture.path) }
    let first = publication(id: "at://did:plc:first/site.standard.publication/main")
    let second = publication(id: "at://did:plc:second/site.standard.publication/main")
    let scopes = [subscribedScope(first), subscribedScope(second)]
    try await fixture.store.replacePublicationScopes(
      viewerDid: fixture.viewerDid,
      scopes: scopes
    )

    let newer = Date(timeIntervalSince1970: 300)
    let older = Date(timeIntervalSince1970: 200)
    try await fixture.store.upsertContentItem(
      item(
        uri: "at://did:plc:first/site.standard.document/newer",
        authorDid: first.authorDid,
        publicationId: first.publicationId,
        createdAt: newer,
        articleUrl: "https://example.com/shared"
      )
    )
    try await fixture.store.upsertContentItem(
      item(
        uri: "at://did:plc:second/site.standard.document/duplicate",
        authorDid: second.authorDid,
        publicationId: second.publicationId,
        createdAt: older,
        articleUrl: "https://example.com/shared?tracking=1"
      )
    )
    try await fixture.store.upsertContentItem(
      item(
        uri: "at://did:plc:second/site.standard.document/unique",
        authorDid: second.authorDid,
        publicationId: second.publicationId,
        createdAt: older.addingTimeInterval(-1),
        articleUrl: "https://example.com/unique"
      )
    )
    try await fixture.store.upsertReadMark(
      viewerDid: fixture.viewerDid,
      subjectUri: "at://did:plc:first/site.standard.document/newer",
      createdAt: newer
    )

    let result = try await fixture.store.listAggregateEntries(
      viewerDid: fixture.viewerDid,
      scopes: scopes,
      filter: .all,
      cursor: nil,
      limit: 50
    )
    #expect(result.response.entries.map(\.entryId) == [
      "at://did:plc:first/site.standard.document/newer",
      "at://did:plc:second/site.standard.document/unique",
    ])
    #expect(result.response.entries.first?.isRead == true)
    #expect(result.diagnostics.duplicatesSuppressed == 1)
    #expect(result.diagnostics.rowsScanned == 3)
  }

  @Test("subscribed scope lookup excludes following-only publications")
  func subscribedScopeLookup() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(atPath: fixture.path) }
    let subscribed = publication(id: "at://did:plc:subscribed/site.standard.publication/main")
    let following = publication(id: "at://did:plc:following/site.standard.publication/main")
    try await fixture.store.replacePublicationScopes(
      viewerDid: fixture.viewerDid,
      scopes: [
        subscribedScope(subscribed),
        AppViewUnreadCounterSupport.publicationScope(
          viewerDid: fixture.viewerDid,
          publicationId: following.publicationId,
          authorDid: following.authorDid,
          publicationAtUri: following.publicationId,
          publicationScopeAtUris: [following.publicationId],
          publicationSiteUrls: [],
          sectionKeys: ["following"]
        ),
      ]
    )

    let scopes = try await fixture.store.publicationScopes(
      viewerDid: fixture.viewerDid,
      sectionKey: "subscribed"
    )
    #expect(scopes.map(\.publicationId) == [subscribed.publicationId])
  }

  private func fixture() throws -> (
    path: String,
    viewerDid: String,
    auth: AuthContext,
    store: SQLiteThinAppViewStore,
    service: ThinAppViewReadService
  ) {
    let logger = Logger(label: "aggregate-feed.test")
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("aggregate-feed-\(UUID().uuidString).sqlite")
      .path
    let store = try SQLiteThinAppViewStore(path: path, logger: logger)
    let viewerDid = "did:plc:viewer"
    return (
      path,
      viewerDid,
      AuthContext(
        did: viewerDid,
        authorizationForwardingValue: "DPoP token",
        dpopProof: "proof"
      ),
      store,
      ThinAppViewReadService(store: store, logger: logger)
    )
  }

  private func subscribedScope(_ publication: SidebarPublicationRow) -> AppViewPublicationScope {
    AppViewUnreadCounterSupport.publicationScope(
      viewerDid: "did:plc:viewer",
      publicationId: publication.publicationId,
      authorDid: publication.authorDid,
      publicationAtUri: publication.publicationId,
      publicationScopeAtUris: [publication.publicationId],
      publicationSiteUrls: [],
      sectionKeys: ["subscribed"]
    )
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
    publishedAt: Date? = nil,
    createdAt: Date? = nil,
    renderedPublishedAt: Date? = nil,
    articleUrl: String? = nil
  ) -> IndexedContentItem {
    let feedPosition = createdAt ?? publishedAt ?? Date()
    let renderedAt = renderedPublishedAt ?? publishedAt ?? feedPosition
    return IndexedContentItem(
      uri: uri,
      cid: uri,
      authorDid: authorDid,
      collection: "site.standard.document",
      createdAt: feedPosition,
      indexedAt: feedPosition,
      publicationSite: publicationId,
      render: ContentRenderFields(
        title: uri,
        publishedAt: ISO8601DateFormatter().string(from: renderedAt),
        articleUrl: articleUrl ?? "https://example.com/\(uri.split(separator: "/").last!)"
      ),
      expiresAt: .distantFuture
    )
  }
}
