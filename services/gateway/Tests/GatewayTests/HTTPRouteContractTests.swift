import AsyncHTTPClient
import Foundation
import GatewayCore
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Logging
import Testing

@testable import Gateway

@Suite("HTTP route contracts")
struct HTTPRouteContractTests {
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

  private func gatewayRouter(
    client: HTTPClient,
    dbPath: String,
    appViewBaseURL: String? = nil
  ) throws -> Router<GatewayRequestContext> {
    let cache = try SQLiteCache(path: dbPath, logger: Logger(label: "contracts.sqlite"))
    var env: [String: String] = [
      "APP_ENV": "local",
      "SQLITE_DB_PATH": dbPath,
    ]
    if let appViewBaseURL, !appViewBaseURL.isEmpty {
      env["APPVIEW_BASE_URL"] = appViewBaseURL
    }
    let config = GatewayServiceConfig.fromEnvironment(env)
    return GatewayRouterBuilder.router(
      config: config,
      httpClient: client,
      cache: cache,
      logger: Logger(label: "contracts.router")
    )
  }

  @Test("health is public")
  func healthEndpoint() async throws {
    try await withSingletonHTTPClient { client in
      let dbPath =
        FileManager.default.temporaryDirectory
          .appendingPathComponent("sw-http-\(UUID().uuidString).sqlite")
          .path
      defer { try? FileManager.default.removeItem(atPath: dbPath) }

      let router = try gatewayRouter(client: client, dbPath: dbPath)
      let app = Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
      try await app.test(.live) { c in
        let response = try await c.execute(uri: "/health", method: .get)
        #expect(response.status == .ok)
      }
    }
  }

  @Test("sync route rejects unauthenticated calls")
  func syncUnauthorized() async throws {
    try await withSingletonHTTPClient { client in
      let dbPath =
        FileManager.default.temporaryDirectory
          .appendingPathComponent("sw-http-\(UUID().uuidString).sqlite")
          .path
      defer { try? FileManager.default.removeItem(atPath: dbPath) }

      let router = try gatewayRouter(client: client, dbPath: dbPath)
      let app = Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
      try await app.test(.live) { c in
        let response = try await c.execute(uri: "/v1/sync/preferences", method: .get)
        #expect(response.status.code == 401)
      }
    }
  }

  @Test("protected route preflight includes configured allow-origin")
  func protectedRoutePreflight() async throws {
    try await withSingletonHTTPClient { client in
      let dbPath =
        FileManager.default.temporaryDirectory
          .appendingPathComponent("sw-http-\(UUID().uuidString).sqlite")
          .path
      defer { try? FileManager.default.removeItem(atPath: dbPath) }

      let env: [String: String] = [
        "APP_ENV": "local",
        "SQLITE_DB_PATH": dbPath,
        "OAUTH_PUBLIC_ORIGIN": "https://testing.thesocialwire.app",
      ]
      let config = GatewayServiceConfig.fromEnvironment(env)
      let cache = try SQLiteCache(path: dbPath, logger: Logger(label: "contracts.sqlite"))
      let router = GatewayRouterBuilder.router(
        config: config,
        httpClient: client,
        cache: cache,
        logger: Logger(label: "contracts.router")
      )
      let app = Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
      try await app.test(.live) { c in
        var headers = HTTPFields()
        headers[.origin] = "https://testing.thesocialwire.app"
        headers[.accessControlRequestMethod] = "GET"
        headers[.accessControlRequestHeaders] = "authorization,dpop"
        let response = try await c.execute(
          uri: "/v1/sync/preferences",
          method: .options,
          headers: headers
        )
        #expect(response.status == .noContent)
        #expect(response.headers[.accessControlAllowOrigin] == "https://testing.thesocialwire.app")
        #expect(response.headers[.accessControlAllowCredentials] == "true")
      }
    }
  }

  @Test("publications sidebar is absent without APPVIEW_BASE_URL")
  func publicationsSidebarAbsentWithoutProxy() async throws {
    try await withSingletonHTTPClient { client in
      let dbPath =
        FileManager.default.temporaryDirectory
          .appendingPathComponent("sw-http-\(UUID().uuidString).sqlite")
          .path
      defer { try? FileManager.default.removeItem(atPath: dbPath) }

      let router = try gatewayRouter(client: client, dbPath: dbPath, appViewBaseURL: nil)
      let app = Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
      try await app.test(.live) { c in
        let response = try await c.execute(uri: "/v1/publications/sidebar", method: .get)
        #expect(response.status.code == 404)
      }
    }
  }

  @Test("latr saves route is absent without LATR_IOS_PROXY_URL")
  func latrSavesAbsentWithoutConfig() async throws {
    try await withSingletonHTTPClient { client in
      let dbPath =
        FileManager.default.temporaryDirectory
          .appendingPathComponent("sw-http-\(UUID().uuidString).sqlite")
          .path
      defer { try? FileManager.default.removeItem(atPath: dbPath) }

      let router = try gatewayRouter(client: client, dbPath: dbPath)
      let app = Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
      try await app.test(.live) { c in
        let response = try await c.execute(uri: "/v1/latr/saves", method: .get)
        #expect(response.status.code == 404)
      }
    }
  }

  @Test("latr saves rejects unauthenticated calls when configured")
  func latrSavesUnauthorizedWhenConfigured() async throws {
    try await withSingletonHTTPClient { client in
      let dbPath =
        FileManager.default.temporaryDirectory
          .appendingPathComponent("sw-http-\(UUID().uuidString).sqlite")
          .path
      defer { try? FileManager.default.removeItem(atPath: dbPath) }

      let env: [String: String] = [
        "APP_ENV": "local",
        "SQLITE_DB_PATH": dbPath,
        "LATR_IOS_PROXY_URL": "https://api.testing.latr.link",
        "LATR_IOS_PROXY_CLIENT_ID": "the-social-wire-ios",
        "LATR_IOS_PROXY_API_KEY": "test-key",
      ]
      let config = GatewayServiceConfig.fromEnvironment(env)
      let cache = try SQLiteCache(path: dbPath, logger: Logger(label: "contracts.sqlite"))
      let router = GatewayRouterBuilder.router(
        config: config,
        httpClient: client,
        cache: cache,
        logger: Logger(label: "contracts.router")
      )
      let app = Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
      try await app.test(.live) { c in
        let response = try await c.execute(uri: "/v1/latr/saves", method: .get)
        #expect(response.status.code == 401)
      }
    }
  }
}

@Suite("ATProtoAuthMiddleware")
struct ATProtoAuthMiddlewareTests {
  @Test("sync route rejects unauthenticated calls")
  func syncUnauthorized() async throws {
    let client = HTTPClient(eventLoopGroupProvider: .singleton)
    let dbPath =
      FileManager.default.temporaryDirectory
        .appendingPathComponent("sw-auth-\(UUID().uuidString).sqlite")
        .path
    defer { try? FileManager.default.removeItem(atPath: dbPath) }

    let cache = try SQLiteCache(path: dbPath, logger: Logger(label: "auth.sqlite"))
    let config = GatewayServiceConfig.fromEnvironment([
      "APP_ENV": "local",
      "SQLITE_DB_PATH": dbPath,
    ])
    let router = GatewayRouterBuilder.router(
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
    try await client.shutdown()
  }
}
