import Foundation
import GatewayCore
import Hummingbird
import HummingbirdTesting
import ReadStateCore
import Testing
import ThinAppViewCore
@testable import AppView

@Test func evictedProjectionBlocksCachedFeedBeforeResponseButLeavesStatusAccessible() async throws {
  let store = ReadinessTestStore()
  let router = Router(context: GatewayRequestContext.self)
  router.add(middleware: ReadinessTestAuth())
  router.add(middleware: PDSReadStateReadinessMiddleware(store: store, recovery: nil))
  router.get("/v1/appview/bootstrap-stream") { _, _ in ["unreadCount": 0] }
  router.get("/xrpc/app.thesocialwire.appview.getReadStateStatus") { _, _ in ["projectionReady": false] }
  let app = Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
  try await app.test(.live) { client in
    let blocked = try await client.execute(uri: "/v1/appview/bootstrap-stream", method: .get)
    #expect(blocked.status.code == 503)
    let json = try #require(JSONSerialization.jsonObject(with: Data(buffer: blocked.body)) as? [String: Any])
    #expect(json["error"] as? String == "ReadStateNotReady")
    #expect(json["retryable"] as? Bool == true)
    #expect(json["unreadCount"] == nil)
    let status = try await client.execute(uri: "/xrpc/app.thesocialwire.appview.getReadStateStatus", method: .get)
    #expect(status.status.code == 200)
    await store.setReady()
    let restored = try await client.execute(uri: "/v1/appview/bootstrap-stream", method: .get)
    #expect(restored.status.code == 200)
  }
}

private struct ReadinessTestAuth: RouterMiddleware {
  typealias Context = GatewayRequestContext
  func handle(_ request: Request, context: GatewayRequestContext,
    next: (Request, GatewayRequestContext) async throws -> Response) async throws -> Response {
    var context = context
    context.authContext = AuthContext(did: "did:plc:viewer", authorizationForwardingValue: "test", dpopProof: "test")
    return try await next(request, context)
  }
}

private actor ReadinessTestStore: PDSReadStateLifecycleStoring {
  var ready = false
  func setReady() { ready = true }
  func touchPDSReadStateAccess(viewerDid: String, at: Date) {}
  func pdsReadStateStatus(viewerDid: String) -> PDSReadStateStatus {
    .init(authority: .pds, migrationState: .verified, legacyRevision: 1, projectionReady: ready)
  }
  func evictIdlePDSReadState(before: Date, at: Date, batchSize: Int) -> PDSReadStateEvictionBatch {
    .init(viewerDid: nil, deletedRows: 0, hasMore: false)
  }
  func exportPDSReadStatePage(viewerDid: String, cursor: String?, expectedLegacyRevision: Int64?, limit: Int) throws -> PDSReadStateExportPage { throw ReadStateError.invalidRecord }
  func activatePDSReadState(viewerDid: String, manifest: ReadStateManifest, manifestCid: String,
    projection: ReadStateProjection, expectedLegacyRevision: Int64?) throws -> PDSReadStateStatus { throw ReadStateError.invalidRecord }
  func preparePDSReadStateBoundaries(viewerDid: String, scopes: [PublicationUnreadScope], at: Date) -> [ReadStateBoundary] { [] }
  func previewPDSReadStateBoundaries(viewerDid: String, boundaries: [ReadStateBoundary], subjectUris: [String]) -> [String] { [] }
}
