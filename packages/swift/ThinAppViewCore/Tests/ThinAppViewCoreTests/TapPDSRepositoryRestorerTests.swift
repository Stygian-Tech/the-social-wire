import AsyncHTTPClient
import Foundation
import Logging
import NIOCore
import NIOHTTP1
import Testing

@testable import ThinAppViewCore

@Suite("Tap PDS repository restoration")
struct TapPDSRepositoryRestorerTests {
  @Test("an incomplete snapshot preserves the last good projection")
  func incompleteSnapshotPreservesProjection() async throws {
    let did = Self.plcDID(endingIn: "2")
    let fixture = try Self.fixture()
    defer { try? FileManager.default.removeItem(atPath: fixture.path) }
    let staleURI = try await Self.seedDocument(
      did: did,
      rkey: "existing",
      title: "Last Good Projection",
      indexer: fixture.indexer
    )
    let transport = OrderedPDSHTTPTransport(
      responses: [
        Self.plcResponse(),
        Self.response(
          status: .badRequest,
          json: ["error": "InvalidRequest", "message": "historical record is invalid"]
        ),
        Self.listRecordsResponse(records: []),
      ]
    )
    let restorer = Self.restorer(fixture: fixture, transport: transport)

    do {
      _ = try await restorer.restoreCurrentRepository(repoDid: did)
      Issue.record("Expected incomplete repository restoration")
    } catch TapRepositoryRestorationError.incomplete(let report) {
      #expect(!report.complete)
    }

    #expect(try await fixture.store.fetchContentItem(uri: staleURI)?.title == "Last Good Projection")
  }

  @Test("a complete snapshot removes only records absent from the PDS")
  func completeSnapshotRemovesStaleProjectionRows() async throws {
    let did = Self.plcDID(endingIn: "3")
    let fixture = try Self.fixture()
    defer { try? FileManager.default.removeItem(atPath: fixture.path) }
    let staleURI = try await Self.seedDocument(
      did: did,
      rkey: "stale",
      title: "Stale",
      indexer: fixture.indexer
    )
    let currentURI = "at://\(did)/site.standard.document/current"
    let transport = OrderedPDSHTTPTransport(
      responses: [
        Self.plcResponse(),
        Self.listRecordsResponse(
          records: [
            Self.documentEnvelope(uri: currentURI, cid: "bafy-current", title: "Current")
          ]
        ),
        Self.listRecordsResponse(records: []),
      ]
    )
    let restorer = Self.restorer(fixture: fixture, transport: transport)

    let report = try await restorer.restoreCurrentRepository(repoDid: did)

    #expect(report.complete)
    #expect(!report.historicalDeletesProvable)
    #expect(try await fixture.store.fetchContentItem(uri: staleURI) == nil)
    #expect(try await fixture.store.fetchContentItem(uri: currentURI)?.title == "Current")
  }

  @Test("document snapshots accept multi-megabyte pages and request smaller pages")
  func largeDocumentPageUsesBoundedCollectionAwareLimit() async throws {
    let did = Self.plcDID(endingIn: "4")
    let fixture = try Self.fixture()
    defer { try? FileManager.default.removeItem(atPath: fixture.path) }
    let currentURI = "at://\(did)/site.standard.document/large"
    let transport = OrderedPDSHTTPTransport(
      responses: [
        Self.plcResponse(),
        Self.listRecordsResponse(
          records: [
            Self.documentEnvelope(
              uri: currentURI,
              cid: "bafy-large",
              title: "Large",
              content: String(repeating: "x", count: 4_600_000)
            )
          ]
        ),
        Self.listRecordsResponse(records: []),
      ]
    )
    let restorer = Self.restorer(fixture: fixture, transport: transport)

    let report = try await restorer.restoreCurrentRepository(repoDid: did)
    let requestURLs = await transport.requestURLs

    #expect(report.complete)
    #expect(try await fixture.store.fetchContentItem(uri: currentURI) != nil)
    #expect(
      requestURLs.contains {
        $0.contains("collection=site.standard.document") && $0.contains("limit=10")
      }
    )
    #expect(
      requestURLs.contains {
        $0.contains("collection=site.standard.entry") && $0.contains("limit=50")
      }
    )
    #expect(ThinAppViewEnrollBackfill.maximumListRecordsResponseBytes == 8 * 1_024 * 1_024)
  }

  @Test("SQLite stale-row cleanup supports snapshots above the bind-variable limit")
  func sqliteCleanupSupportsLargeObservedSnapshots() async throws {
    let did = Self.plcDID(endingIn: "5")
    let fixture = try Self.fixture()
    defer { try? FileManager.default.removeItem(atPath: fixture.path) }
    let retainedURI = try await Self.seedDocument(
      did: did,
      rkey: "retained",
      title: "Retained",
      indexer: fixture.indexer
    )
    let staleURI = try await Self.seedDocument(
      did: did,
      rkey: "stale",
      title: "Stale",
      indexer: fixture.indexer
    )
    let observedURIs = [retainedURI]
      + (0..<1_100).map { "at://\(did)/site.standard.document/not-local-\($0)" }

    let deleted = try await fixture.store.deleteContentItems(
      authorDid: did,
      excludingURIs: observedURIs,
      indexedAtOrBefore: Date()
    )

    #expect(deleted == 1)
    #expect(try await fixture.store.fetchContentItem(uri: retainedURI) != nil)
    #expect(try await fixture.store.fetchContentItem(uri: staleURI) == nil)
  }

  @Test("an empty complete snapshot repairs counters and invalidates projection caches")
  func emptySnapshotRepairsDerivedState() async throws {
    let did = Self.plcDID(endingIn: "6")
    let fixture = try Self.fixture()
    defer { try? FileManager.default.removeItem(atPath: fixture.path) }
    let cachePath = FileManager.default.temporaryDirectory
      .appendingPathComponent("tap-restorer-cache-\(UUID().uuidString).sqlite").path
    defer { try? FileManager.default.removeItem(atPath: cachePath) }
    let cache = try SQLiteAppViewProjectionCacheStore(path: cachePath, logger: fixture.logger)
    let viewerDid = "did:plc:\(String(repeating: "b", count: 24))"
    let publicationID = "at://\(did)/site.standard.publication/main"
    let scope = AppViewUnreadCounterSupport.publicationScope(
      viewerDid: viewerDid,
      publicationId: publicationID,
      authorDid: did,
      publicationAtUri: publicationID,
      publicationScopeAtUris: [],
      publicationSiteUrls: [],
      sectionKeys: [],
      updatedAt: Date()
    )
    try await fixture.store.upsertPublicationScopes([scope])
    let staleURI = try await Self.seedDocument(
      did: did,
      rkey: "only-record",
      title: "Only Record",
      publicationSite: publicationID,
      indexer: fixture.indexer
    )
    let expiresAt = Date().addingTimeInterval(3_600)
    try await cache.storeSidebarProjectionJSON(
      viewerDid: viewerDid,
      jsonBody: #"{"priority":{}}"#,
      expiresAt: expiresAt
    )
    try await cache.storeUnreadCounts(
      viewerDid: viewerDid,
      counts: [publicationID: 1],
      expiresAt: expiresAt
    )
    try await cache.storeFirstPageJSON(
      viewerDid: viewerDid,
      publicationId: publicationID,
      jsonBody: #"{"entries":[{"entryId":"stale"}]}"#,
      expiresAt: expiresAt
    )
    let transport = OrderedPDSHTTPTransport(
      responses: [
        Self.plcResponse(),
        Self.listRecordsResponse(records: []),
        Self.listRecordsResponse(records: []),
      ]
    )
    let restorer = Self.restorer(
      fixture: fixture,
      transport: transport,
      projectionCache: cache
    )

    let report = try await restorer.restoreCurrentRepository(repoDid: did)
    let dirtyCounter = try await fixture.store.fetchUnreadCounters(
      viewerDid: viewerDid,
      publicationIds: [publicationID]
    ).first
    let refreshed = try await fixture.store.refreshUnreadCounters(
      viewerDid: viewerDid,
      scopes: [
        PublicationUnreadScope(
          publicationId: publicationID,
          authorDid: did,
          publicationAtUri: publicationID,
          publicationScopeAtUris: [],
          publicationSiteUrls: []
        )
      ]
    )

    #expect(report.complete)
    #expect(try await fixture.store.fetchContentItem(uri: staleURI) == nil)
    #expect(dirtyCounter?.dirty == true)
    #expect(refreshed.first?.unreadCount == 0)
    #expect(try await cache.cachedSidebarProjectionJSON(viewerDid: viewerDid) == nil)
    #expect(try await cache.cachedUnreadCounts(viewerDid: viewerDid) == nil)
    #expect(
      try await cache.cachedFirstPageJSON(
        viewerDid: viewerDid,
        publicationId: publicationID
      ) == nil
    )
  }

  @Test("snapshot pruning preserves a commit indexed after the snapshot began")
  func snapshotCutoffPreservesConcurrentCommit() async throws {
    let did = Self.plcDID(endingIn: "7")
    let fixture = try Self.fixture()
    defer { try? FileManager.default.removeItem(atPath: fixture.path) }
    let staleURI = try await Self.seedDocument(
      did: did,
      rkey: "stale",
      title: "Stale",
      indexer: fixture.indexer
    )
    let concurrentURI = "at://\(did)/site.standard.document/concurrent"
    let now = Date()
    try await fixture.store.upsertContentItem(
      IndexedContentItem(
        uri: concurrentURI,
        cid: "bafy-concurrent",
        authorDid: did,
        collection: "site.standard.document",
        createdAt: now,
        indexedAt: now.addingTimeInterval(60),
        publicationSite: nil,
        render: ContentRenderFields(
          title: "Concurrent",
          publishedAt: ISO8601DateFormatter().string(from: now)
        ),
        expiresAt: now.addingTimeInterval(3_600)
      )
    )
    let transport = OrderedPDSHTTPTransport(
      responses: [
        Self.plcResponse(),
        Self.listRecordsResponse(records: []),
        Self.listRecordsResponse(records: []),
      ]
    )

    _ = try await Self.restorer(
      fixture: fixture,
      transport: transport
    ).restoreCurrentRepository(repoDid: did)

    #expect(try await fixture.store.fetchContentItem(uri: staleURI) == nil)
    #expect(try await fixture.store.fetchContentItem(uri: concurrentURI)?.title == "Concurrent")
  }

  @Test("a repository deadline cancels stalled PDS work without pruning the last good snapshot")
  func repositoryDeadlinePreservesProjection() async throws {
    let did = Self.plcDID(endingIn: "c")
    let fixture = try Self.fixture()
    defer { try? FileManager.default.removeItem(atPath: fixture.path) }
    let staleURI = try await Self.seedDocument(
      did: did,
      rkey: "existing",
      title: "Last Good Projection",
      indexer: fixture.indexer
    )
    let cancellation = RepositoryRestorationCancellationProbe()
    let transport = StallingPDSHTTPTransport(
      plcResponse: Self.plcResponse(),
      cancellation: cancellation
    )
    let restorer = Self.restorer(
      fixture: fixture,
      transport: transport,
      timeoutSeconds: 0.05
    )

    do {
      _ = try await restorer.restoreCurrentRepository(repoDid: did)
      Issue.record("Expected repository restoration timeout")
    } catch TapRepositoryRestorationError.timedOut {
      // Expected.
    }

    #expect(await cancellation.wasObserved)
    #expect(try await fixture.store.fetchContentItem(uri: staleURI)?.title == "Last Good Projection")
  }

  private static func fixture() throws -> RepositoryRestorationFixture {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("tap-restorer-\(UUID().uuidString).sqlite").path
    let logger = Logger(label: "tap.restorer.test")
    let store = try SQLiteThinAppViewStore(path: path, logger: logger)
    let config = ThinAppViewConfig.fromEnvironment(["ENABLE_THIN_APPVIEW": "true"])
    let indexer = ThinAppViewIndexer(
      store: store,
      config: config,
      logger: logger,
      publicationSiteResolver: nil
    )
    return RepositoryRestorationFixture(
      path: path,
      logger: logger,
      store: store,
      config: config,
      indexer: indexer
    )
  }

  private static func restorer(
    fixture: RepositoryRestorationFixture,
    transport: any PDSHTTPTransport,
    projectionCache: (any AppViewProjectionCacheStore)? = nil,
    timeoutSeconds: TimeInterval = 120
  ) -> TapPDSRepositoryRestorer {
    let backfill = ThinAppViewEnrollBackfill(
      store: fixture.store,
      indexer: fixture.indexer,
      httpTransport: transport,
      endpointPolicy: .localTesting,
      plcURL: "http://127.0.0.1:3000",
      config: fixture.config,
      logger: fixture.logger
    )
    return TapPDSRepositoryRestorer(
      store: fixture.store,
      backfill: backfill,
      projectionCache: projectionCache,
      maxConcurrency: 1,
      rateLimitPerSecond: 1_000,
      timeoutSeconds: timeoutSeconds
    )
  }

  private static func seedDocument(
    did: String,
    rkey: String,
    title: String,
    publicationSite: String? = nil,
    indexer: ThinAppViewIndexer
  ) async throws -> String {
    let uri = "at://\(did)/site.standard.document/\(rkey)"
    var record: [String: Any] = [
      "title": title,
      "publishedAt": "2026-08-15T12:00:00.000Z",
      "content": "Body",
    ]
    if let publicationSite { record["site"] = publicationSite }
    let recordJSON = try JSONSerialization.data(withJSONObject: record)
    try await indexer.handleCommit(
      repoDid: did,
      collection: "site.standard.document",
      rkey: rkey,
      cid: "bafy-\(rkey)",
      recordJSON: recordJSON,
      operation: "create"
    )
    return uri
  }

  private static func plcDID(endingIn suffix: String) -> String {
    "did:plc:\(String(repeating: "a", count: 23))\(suffix)"
  }

  private static func plcResponse() -> HTTPClientResponse {
    response(
      status: .ok,
      json: [
        "service": [
          [
            "id": "#atproto_pds",
            "type": "AtprotoPersonalDataServer",
            "serviceEndpoint": "http://127.0.0.1:8080",
          ]
        ]
      ]
    )
  }

  private static func listRecordsResponse(records: [[String: Any]]) -> HTTPClientResponse {
    response(status: .ok, json: ["records": records])
  }

  private static func documentEnvelope(
    uri: String,
    cid: String,
    title: String,
    content: String = "Body"
  ) -> [String: Any] {
    [
      "uri": uri,
      "cid": cid,
      "value": [
        "title": title,
        "publishedAt": "2026-08-15T12:00:00.000Z",
        "content": content,
      ],
    ]
  }

  private static func response(
    status: HTTPResponseStatus,
    json: [String: Any]
  ) -> HTTPClientResponse {
    let data = try! JSONSerialization.data(withJSONObject: json)
    var buffer = ByteBufferAllocator().buffer(capacity: data.count)
    buffer.writeBytes(data)
    return HTTPClientResponse(status: status, body: .bytes(buffer))
  }
}

private struct RepositoryRestorationFixture {
  let path: String
  let logger: Logger
  let store: SQLiteThinAppViewStore
  let config: ThinAppViewConfig
  let indexer: ThinAppViewIndexer
}

private actor OrderedPDSHTTPTransport: PDSHTTPTransport {
  private var responses: [HTTPClientResponse]
  private(set) var requestURLs: [String] = []

  init(responses: [HTTPClientResponse]) {
    self.responses = responses
  }

  func execute(
    _ request: HTTPClientRequest,
    timeout: TimeAmount
  ) async throws -> HTTPClientResponse {
    _ = timeout
    requestURLs.append(request.url)
    guard !responses.isEmpty else {
      throw OrderedPDSHTTPTransportError.unexpectedRequest(request.url)
    }
    return responses.removeFirst()
  }
}

private enum OrderedPDSHTTPTransportError: Error {
  case unexpectedRequest(String)
}

private actor RepositoryRestorationCancellationProbe {
  private(set) var wasObserved = false

  func observe() {
    wasObserved = true
  }
}

private actor StallingPDSHTTPTransport: PDSHTTPTransport {
  private let plcResponse: HTTPClientResponse
  private let cancellation: RepositoryRestorationCancellationProbe
  private var requestCount = 0

  init(
    plcResponse: HTTPClientResponse,
    cancellation: RepositoryRestorationCancellationProbe
  ) {
    self.plcResponse = plcResponse
    self.cancellation = cancellation
  }

  func execute(
    _ request: HTTPClientRequest,
    timeout: TimeAmount
  ) async throws -> HTTPClientResponse {
    _ = request
    _ = timeout
    requestCount += 1
    if requestCount == 1 { return plcResponse }
    return HTTPClientResponse(
      status: .ok,
      body: .stream(StallingRepositoryBodySequence(cancellation: cancellation))
    )
  }
}

private struct StallingRepositoryBodySequence: AsyncSequence, Sendable {
  typealias Element = ByteBuffer

  struct AsyncIterator: AsyncIteratorProtocol {
    let cancellation: RepositoryRestorationCancellationProbe

    mutating func next() async throws -> ByteBuffer? {
      do {
        try await Task.sleep(for: .seconds(60))
        return nil
      } catch {
        await cancellation.observe()
        throw error
      }
    }
  }

  let cancellation: RepositoryRestorationCancellationProbe

  func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(cancellation: cancellation)
  }
}
