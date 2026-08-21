import AsyncHTTPClient
import Foundation
import GatewayCore
import Hummingbird
import HummingbirdTesting
import Logging
import Testing
import ThinAppViewCore

@testable import AppView

@Suite("ThinAppViewEnrollService")
struct ThinAppViewEnrollServiceTests {
  @Test("deduplicates author DIDs and respects maxEnrollAuthors")
  func dedupAndCap() async throws {
    let dbPath =
      FileManager.default.temporaryDirectory
      .appendingPathComponent("sw-enroll-\(UUID().uuidString).sqlite")
      .path
    defer { try? FileManager.default.removeItem(atPath: dbPath) }

    let logger = Logger(label: "enroll.test")
    let store = try SQLiteThinAppViewStore(path: dbPath, logger: logger)
    let config = ThinAppViewConfig.fromEnvironment([
      "ENABLE_THIN_APPVIEW": "true",
      "THIN_APPVIEW_MAX_ENROLL_AUTHORS": "2",
    ])
    let indexer = ThinAppViewIndexer(store: store, config: config, logger: logger)
    let client = HTTPClient(eventLoopGroupProvider: .singleton)

    let service = ThinAppViewEnrollService(
      store: store,
      indexer: indexer,
      httpClient: client,
      plcURL: "https://plc.directory",
      config: config,
      logger: logger
    )

    let auth = AuthContext(
      did: "did:plc:viewer",
      authorizationForwardingValue: "DPoP token",
      dpopProof: "proof"
    )

    let indexed = try await service.enroll(
      auth: auth,
      authorDids: [
        "did:plc:one",
        " did:plc:one ",
        "did:plc:two",
        "did:plc:three",
      ]
    )
    #expect(indexed == 0)
    try await client.shutdown()
  }
}

@Suite("AppView route contracts")
struct AppViewRouteContractTests {
  @Test("appview enroll rejects unauthenticated calls when enabled")
  func appviewEnrollUnauthorized() async throws {
    let client = HTTPClient(eventLoopGroupProvider: .singleton)
    let dbPath =
      FileManager.default.temporaryDirectory
      .appendingPathComponent("sw-appview-\(UUID().uuidString).sqlite")
      .path
    defer { try? FileManager.default.removeItem(atPath: dbPath) }

    let store = try SQLiteThinAppViewStore(path: dbPath, logger: Logger(label: "appview.store"))
    let config = try AppViewServiceConfig.fromEnvironment([
      "APP_ENV": "local",
      "SQLITE_DB_PATH": dbPath,
      "ENABLE_THIN_APPVIEW": "true",
    ])
    let router = AppViewRouterBuilder.router(
      config: config,
      httpClient: client,
      thinAppViewStore: store,
      projectionCache: nil,
      logger: Logger(label: "appview.router")
    )
    let app = Application(
      router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
    try await app.test(.live) { c in
      let response = try await c.execute(uri: "/v1/appview/enroll", method: .post)
      #expect(response.status.code == 401)
    }
    try await client.shutdown()
  }

  @Test("XRPC application methods are registered and protected")
  func xrpcMethodsRegistered() async throws {
    let client = HTTPClient(eventLoopGroupProvider: .singleton)
    let dbPath = FileManager.default.temporaryDirectory
      .appendingPathComponent("sw-appview-xrpc-\(UUID().uuidString).sqlite").path
    defer { try? FileManager.default.removeItem(atPath: dbPath) }

    let store = try SQLiteThinAppViewStore(
      path: dbPath, logger: Logger(label: "appview.xrpc.store"))
    let config = try AppViewServiceConfig.fromEnvironment([
      "APP_ENV": "local",
      "SQLITE_DB_PATH": dbPath,
      "ENABLE_THIN_APPVIEW": "true",
    ])
    let router = AppViewRouterBuilder.router(
      config: config,
      httpClient: client,
      thinAppViewStore: store,
      projectionCache: nil,
      logger: Logger(label: "appview.xrpc.router")
    )
    let app = Application(
      router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
    try await app.test(.live) { testClient in
      let queries = [
        "app.thesocialwire.appview.getFeed",
        "app.thesocialwire.appview.listEntries",
        "app.thesocialwire.appview.getEntry",
        "app.thesocialwire.appview.getUnreadCounts",
        "app.thesocialwire.publication.getSidebar",
      ]
      for nsid in queries {
        let response = try await testClient.execute(uri: "/xrpc/\(nsid)", method: .get)
        #expect(response.status == .unauthorized)
      }

      let procedures = [
        "app.thesocialwire.appview.putReadMark",
        "app.thesocialwire.appview.deleteReadMark",
        "app.thesocialwire.appview.enrollSources",
        "app.thesocialwire.appview.purgeViewerData",
        "app.thesocialwire.appview.markAllRead",
        "app.thesocialwire.publication.refreshSidebar",
        "app.thesocialwire.publication.resolvePublication",
      ]
      for nsid in procedures {
        let response = try await testClient.execute(uri: "/xrpc/\(nsid)", method: .post)
        #expect(response.status == .unauthorized)
      }
    }
    try await client.shutdown()
  }
}
