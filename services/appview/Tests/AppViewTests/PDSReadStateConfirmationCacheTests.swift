import AsyncHTTPClient
import Foundation
import GatewayCore
import Hummingbird
import HummingbirdTesting
import Logging
import ReadStateCore
import Testing
import ThinAppViewCore
@testable import AppView

@Test func verifiedConfirmationInvalidatesOnlyTheConfirmedViewersProjections() async throws {
  let path = FileManager.default.temporaryDirectory.appendingPathComponent("pds-confirm-\(UUID().uuidString).sqlite").path
  defer { try? FileManager.default.removeItem(atPath: path) }
  let cache = try SQLiteAppViewProjectionCacheStore(path: path, logger: Logger(label: "pds-confirm-cache.test"))
  let viewer = "did:plc:confirmed"
  let other = "did:plc:other"
  let publication = "publication"
  for did in [viewer, other] {
    try await cache.storeSidebarProjectionJSON(viewerDid: did, jsonBody: "{}", expiresAt: Date().addingTimeInterval(300))
    try await cache.storeUnreadCounts(viewerDid: did, counts: [publication: 7], expiresAt: Date().addingTimeInterval(300))
    try await cache.storeFirstPageJSON(viewerDid: did, publicationId: publication, jsonBody: "{}", expiresAt: Date().addingTimeInterval(300))
  }
  let store = ConfirmationStore()
  let manifest = ReadStateManifest(generation: "empty", lastSequence: 0, head: nil)
  let projection = try ReadStateProjection(operations: [], lastSequence: 0)
  // Failed parity must preserve every cache and the old authority.
  await #expect(throws: PDSReadStateStorageError.parityMismatch) {
    try await PDSReadStateService.activateVerifiedGeneration(store: store, projectionCache: cache,
      viewerDid: viewer, manifest: manifest, manifestCid: "verified", projection: projection, expectedLegacyRevision: 1)
  }
  #expect(try await cache.sidebarProjectionCacheEntry(viewerDid: viewer) != nil)
  #expect(try await cache.unreadCountsCacheEntry(viewerDid: viewer)?.value[publication] == 7)
  #expect(try await cache.firstPageCacheEntry(viewerDid: viewer, publicationId: publication) != nil)
  await store.allowActivation()
  let status = try await PDSReadStateService.activateVerifiedGeneration(store: store, projectionCache: cache,
    viewerDid: viewer, manifest: manifest, manifestCid: "verified", projection: projection, expectedLegacyRevision: 1)
  #expect(status.authority == .pds)
  #expect(try await cache.sidebarProjectionCacheEntry(viewerDid: viewer) == nil)
  #expect(try await cache.unreadCountsCacheEntry(viewerDid: viewer) == nil)
  #expect(try await cache.firstPageCacheEntry(viewerDid: viewer, publicationId: publication) == nil)
  #expect(try await cache.sidebarProjectionCacheEntry(viewerDid: other) != nil)
  #expect(try await cache.unreadCountsCacheEntry(viewerDid: other)?.value[publication] == 7)
  #expect(try await cache.firstPageCacheEntry(viewerDid: other, publicationId: publication) != nil)
}

private actor ConfirmationStore: PDSReadStateStoring {
  private var allowed = false
  private let exportError: PDSReadStateStorageError
  init(exportError: PDSReadStateStorageError = .alreadyMigrated) { self.exportError = exportError }
  func allowActivation() { allowed = true }
  func pdsReadStateStatus(viewerDid: String) -> PDSReadStateStatus {
    .init(authority: .appview, migrationState: .notStarted, legacyRevision: 1)
  }
  func activatePDSReadState(viewerDid: String, manifest: ReadStateManifest, manifestCid: String,
    projection: ReadStateProjection, expectedLegacyRevision: Int64?) throws -> PDSReadStateStatus {
    guard allowed else { throw PDSReadStateStorageError.parityMismatch }
    return .init(authority: .pds, migrationState: .verified, legacyRevision: 1, manifest: manifest, manifestCid: manifestCid)
  }
  func exportPDSReadStatePage(viewerDid: String, cursor: String?, expectedLegacyRevision: Int64?, limit: Int) throws -> PDSReadStateExportPage { throw exportError }
  func preparePDSReadStateBoundaries(viewerDid: String, scopes: [PublicationUnreadScope], at: Date) -> [ReadStateBoundary] { [] }
  func previewPDSReadStateBoundaries(viewerDid: String, boundaries: [ReadStateBoundary], subjectUris: [String]) -> [String] { [] }
}


@Test func scopeParityConflictReturnsRetryableMigrationError() async throws {
  let path = FileManager.default.temporaryDirectory.appendingPathComponent("pds-scope-route-\(UUID().uuidString).sqlite").path
  defer { try? FileManager.default.removeItem(atPath: path) }
  let logger = Logger(label: "pds-scope-route.test")
  let thinStore = try SQLiteThinAppViewStore(path: path, logger: logger)
  let http = HTTPClient(eventLoopGroupProvider: .singleton)
  do {
    let publicationService = PublicationProjectionService(httpClient: http, plcURL: "https://plc.directory",
      logger: logger, thinStore: thinStore)
    let service = PDSReadStateService(store: ConfirmationStore(exportError: .legacyScopeOverlap), thinStore: thinStore,
      repo: ATProtoAuthenticatedRepoClient(httpClient: http, plcURL: "https://plc.directory", logger: logger),
      publicationService: publicationService, projectionCache: nil)
    let router = Router(context: GatewayRequestContext.self)
    router.add(middleware: ScopeParityTestAuth())
    PDSReadStateRoutes(service: service).register(on: router.group())
    let app = Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
    try await app.test(.live) { client in
      let response = try await client.execute(uri: "/xrpc/app.thesocialwire.appview.exportReadState", method: .post,
        headers: [.contentType: "application/json"], body: .init(string: "{}"))
      #expect(response.status.code == 409)
      let error = try JSONDecoder().decode(AppViewFeedErrorEnvelope.self, from: Data(buffer: response.body))
      #expect(error.error == "ReadStateMigrationScopeConflict")
      #expect(error.retryable)
      #expect(error.message.contains("existing read state is preserved"))
    }
  } catch {
    try? await http.shutdown()
    throw error
  }
  try await http.shutdown()
}

private struct ScopeParityTestAuth: RouterMiddleware {
  typealias Context = GatewayRequestContext
  func handle(_ request: Request, context: GatewayRequestContext,
    next: (Request, GatewayRequestContext) async throws -> Response) async throws -> Response {
    var context = context
    context.authContext = AuthContext(did: "did:plc:viewer", authorizationForwardingValue: "test", dpopProof: "test")
    return try await next(request, context)
  }
}
