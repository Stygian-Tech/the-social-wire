import AsyncHTTPClient
import Foundation
import Logging
import Testing
import ThinAppViewCore

@testable import App

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
