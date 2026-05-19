import AsyncHTTPClient
import Foundation
import Hummingbird
import HummingbirdTesting
import Logging
import Testing

@testable import App

@Suite("HTTP route contracts")
struct HTTPRouteContractTests {
  /// Ensures pooled clients always reach `shutdown()` despite intermediate throw sites.
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

  @Test("health is public")
  func healthEndpoint() async throws {
    try await withSingletonHTTPClient { client in
      let dbPath =
        FileManager.default.temporaryDirectory
          .appendingPathComponent("sw-http-\(UUID().uuidString).sqlite")
          .path
      defer { try? FileManager.default.removeItem(atPath: dbPath) }

      let cache = try SQLiteCache(path: dbPath, logger: Logger(label: "contracts.sqlite"))
      let config = AppConfig(
        atprotoPLCURL: "https://plc.directory",
        appEnv: .local,
        cacheBackend: .sqlite(path: dbPath),
        oauthPublicOrigin: nil,
        oauthIosMetadataOrigin: nil,
        enableLegacyContentAPI: false,
        thinAppView: .disabled,
        oauthGateway: OAuthGatewayClientPolicy.permissive
      )

      let router = AppRouterBuilder.router(
        config: config,
        httpClient: client,
        cache: cache,
        logger: Logger(label: "contracts.router")
      )

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

      let cache = try SQLiteCache(path: dbPath, logger: Logger(label: "contracts.sqlite"))
      let config = AppConfig(
        atprotoPLCURL: "https://plc.directory",
        appEnv: .local,
        cacheBackend: .sqlite(path: dbPath),
        oauthPublicOrigin: nil,
        oauthIosMetadataOrigin: nil,
        enableLegacyContentAPI: false,
        thinAppView: .disabled,
        oauthGateway: OAuthGatewayClientPolicy.permissive
      )

      let router = AppRouterBuilder.router(
        config: config,
        httpClient: client,
        cache: cache,
        logger: Logger(label: "contracts.router")
      )

      let app = Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
      try await app.test(.live) { c in
        let response = try await c.execute(uri: "/v1/sync/preferences", method: .get)
        #expect(response.status.code == 401)
      }
    }
  }

  @Test("legacy discovery is absent unless ENABLE_LEGACY_CONTENT_API")
  func legacyDiscoveryAbsent() async throws {
    try await withSingletonHTTPClient { client in
      let dbPath =
        FileManager.default.temporaryDirectory
          .appendingPathComponent("sw-http-\(UUID().uuidString).sqlite")
          .path
      defer { try? FileManager.default.removeItem(atPath: dbPath) }

      let cache = try SQLiteCache(path: dbPath, logger: Logger(label: "contracts.sqlite"))
      let config = AppConfig(
        atprotoPLCURL: "https://plc.directory",
        appEnv: .local,
        cacheBackend: .sqlite(path: dbPath),
        oauthPublicOrigin: nil,
        oauthIosMetadataOrigin: nil,
        enableLegacyContentAPI: false,
        thinAppView: .disabled,
        oauthGateway: OAuthGatewayClientPolicy.permissive
      )

      let router = AppRouterBuilder.router(
        config: config,
        httpClient: client,
        cache: cache,
        logger: Logger(label: "contracts.router")
      )

      let app = Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
      try await app.test(.live) { c in
        let response = try await c.execute(uri: "/discovery/refresh", method: .post)
        #expect(response.status.code == 404)
      }
    }
  }
}
