import AsyncHTTPClient
import Foundation
import Hummingbird
import HummingbirdTesting
import Logging
import Testing
import ThinAppViewCore

@testable import App

@Suite("ATProtoAuthMiddleware")
struct ATProtoAuthMiddlewareTests {
  private func withSingletonHTTPClient(
    perform: @escaping @Sendable (HTTPClient) async throws -> Void
  ) async throws {
    let client = HTTPClient(eventLoopGroupProvider: .singleton)
    do {
      try await perform(client)
    } catch {
      try await client.shutdown()
      throw error
    }
    try await client.shutdown()
  }

  @Test("sync route rejects unauthenticated calls")
  func syncUnauthorized() async throws {
    try await withSingletonHTTPClient { client in
      let dbPath =
        FileManager.default.temporaryDirectory
          .appendingPathComponent("sw-auth-\(UUID().uuidString).sqlite")
          .path
      defer { try? FileManager.default.removeItem(atPath: dbPath) }

      let cache = try SQLiteCache(path: dbPath, logger: Logger(label: "auth.sqlite"))
      let config = AppConfig.fromEnvironment([:])
      let router = AppRouterBuilder.router(
        config: config,
        httpClient: client,
        cache: cache,
        logger: Logger(label: "auth.router")
      )
      let app = Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
      try await app.test(.live) { c in
        let response = try await c.execute(uri: "/v1/sync/preferences", method: .get)
        #expect(response.status.code == 401)
      }
    }
  }
}

@Suite("ThinAppViewRoutes")
struct ThinAppViewRoutesTests {
  private func withSingletonHTTPClient(
    perform: @escaping @Sendable (HTTPClient) async throws -> Void
  ) async throws {
    let client = HTTPClient(eventLoopGroupProvider: .singleton)
    do {
      try await perform(client)
    } catch {
      try await client.shutdown()
      throw error
    }
    try await client.shutdown()
  }

  @Test("appview routes absent when ENABLE_THIN_APPVIEW is false")
  func appviewAbsentWhenDisabled() async throws {
    try await withSingletonHTTPClient { client in
      let dbPath =
        FileManager.default.temporaryDirectory
          .appendingPathComponent("sw-appview-\(UUID().uuidString).sqlite")
          .path
      defer { try? FileManager.default.removeItem(atPath: dbPath) }

      let cache = try SQLiteCache(path: dbPath, logger: Logger(label: "appview.sqlite"))
      let config = AppConfig.fromEnvironment(["ENABLE_THIN_APPVIEW": "false"])
      let router = AppRouterBuilder.router(
        config: config,
        httpClient: client,
        cache: cache,
        logger: Logger(label: "appview.router")
      )
      let app = Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
      try await app.test(.live) { c in
        let response = try await c.execute(uri: "/v1/appview/entries?authorDid=did:plc:test", method: .get)
        #expect(response.status.code == 404)
      }
    }
  }

  @Test("appview enroll rejects unauthenticated calls when enabled")
  func appviewEnrollUnauthorized() async throws {
    try await withSingletonHTTPClient { client in
      let dbPath =
        FileManager.default.temporaryDirectory
          .appendingPathComponent("sw-appview-\(UUID().uuidString).sqlite")
          .path
      defer { try? FileManager.default.removeItem(atPath: dbPath) }

      let cache = try SQLiteCache(path: dbPath, logger: Logger(label: "appview.sqlite"))
      let thinStore = try SQLiteThinAppViewStore(path: dbPath, logger: Logger(label: "appview.store"))
      let config = AppConfig.fromEnvironment(["ENABLE_THIN_APPVIEW": "true"])
      let router = AppRouterBuilder.router(
        config: config,
        httpClient: client,
        cache: cache,
        logger: Logger(label: "appview.router"),
        thinAppViewStore: thinStore
      )
      let app = Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
      try await app.test(.live) { c in
        let response = try await c.execute(uri: "/v1/appview/enroll", method: .post)
        #expect(response.status.code == 401)
      }
    }
  }
}
