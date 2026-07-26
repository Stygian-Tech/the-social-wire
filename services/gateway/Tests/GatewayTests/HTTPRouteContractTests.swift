import AsyncHTTPClient
import Foundation
import GatewayCore
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Logging
import NIOHTTP1
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
    appViewBaseURL: String? = nil,
    operationsBaseURL: String? = nil
  ) throws -> Router<GatewayRequestContext> {
    let cache = try SQLiteCache(path: dbPath, logger: Logger(label: "contracts.sqlite"))
    var env: [String: String] = [
      "APP_ENV": "local",
      "SQLITE_DB_PATH": dbPath,
    ]
    if let appViewBaseURL, !appViewBaseURL.isEmpty {
      env["APPVIEW_BASE_URL"] = appViewBaseURL
    }
    if let operationsBaseURL, !operationsBaseURL.isEmpty {
      env["OPERATIONS_BASE_URL"] = operationsBaseURL
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

  @Test("operations overview is absent without OPERATIONS_BASE_URL")
  func operationsOverviewAbsentWithoutBaseURL() async throws {
    try await withSingletonHTTPClient { client in
      let dbPath =
        FileManager.default.temporaryDirectory
          .appendingPathComponent("sw-http-\(UUID().uuidString).sqlite")
          .path
      defer { try? FileManager.default.removeItem(atPath: dbPath) }

      let router = try gatewayRouter(client: client, dbPath: dbPath)
      let app = Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
      try await app.test(.live) { c in
        let response = try await c.execute(uri: "/v1/operations/overview", method: .get)
        #expect(response.status == .notFound)
      }
    }
  }

  @Test("operations overview rejects unauthenticated calls when configured")
  func operationsOverviewUnauthorizedWhenConfigured() async throws {
    try await withSingletonHTTPClient { client in
      let dbPath =
        FileManager.default.temporaryDirectory
          .appendingPathComponent("sw-http-\(UUID().uuidString).sqlite")
          .path
      defer { try? FileManager.default.removeItem(atPath: dbPath) }

      let router = try gatewayRouter(
        client: client,
        dbPath: dbPath,
        operationsBaseURL: "https://operations.example"
      )
      let app = Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
      try await app.test(.live) { c in
        let response = try await c.execute(uri: "/v1/operations/overview", method: .get)
        #expect(response.status == .unauthorized)
      }
    }
  }

  @Test("operations reconnect rejects unauthenticated calls when configured")
  func operationsReconnectUnauthorizedWhenConfigured() async throws {
    try await withSingletonHTTPClient { client in
      let dbPath =
        FileManager.default.temporaryDirectory
          .appendingPathComponent("sw-http-\(UUID().uuidString).sqlite")
          .path
      defer { try? FileManager.default.removeItem(atPath: dbPath) }

      let router = try gatewayRouter(
        client: client,
        dbPath: dbPath,
        operationsBaseURL: "https://operations.example"
      )
      let app = Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
      try await app.test(.live) { c in
        let response = try await c.execute(
          uri: "/v1/operations/ingestion/reconnect",
          method: .post
        )
        #expect(response.status == .unauthorized)
      }
    }
  }

  @Test("protected route preflight allows Operations mutation, tracing, and event resume contract")
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
        "OAUTH_OPERATIONS_ORIGIN": "https://operations.testing.thesocialwire.app",
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
        headers[.origin] = "https://operations.testing.thesocialwire.app"
        headers[.accessControlRequestMethod] = "PATCH"
        headers[.accessControlRequestHeaders] =
          "authorization,dpop,traceparent,x-request-id,idempotency-key,last-event-id"
        let response = try await c.execute(
          uri: "/v1/sync/preferences",
          method: .options,
          headers: headers
        )
        #expect(response.status == .noContent)
        #expect(response.headers[.accessControlAllowOrigin] == "https://operations.testing.thesocialwire.app")
        #expect(response.headers[.accessControlAllowCredentials] == "true")
        let allowedHeaders = Set(
          (response.headers[.accessControlAllowHeaders] ?? "")
            .lowercased()
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        )
        #expect(allowedHeaders.isSuperset(of: [
          "authorization",
          "dpop",
          "idempotency-key",
          "last-event-id",
          "traceparent",
          "x-request-id",
        ]))
        let allowedMethods = Set(
          (response.headers[.accessControlAllowMethods] ?? "")
            .lowercased()
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        )
        #expect(allowedMethods.contains("patch"))
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

  @Test("operations proxy preserves upstream status codes")
  func operationsProxyStatusMapping() {
    #expect(OperationsProxyRoutes.status(202).code == 202)
    #expect(OperationsProxyRoutes.status(418).code == 418)
    #expect(OperationsProxyRoutes.status(429).code == 429)
    #expect(OperationsProxyRoutes.status(503).code == 503)
    #expect(OperationsProxyRoutes.status(999) == .badGateway)
  }

  @Test("operations proxy preserves operational response metadata")
  func operationsProxyResponseHeaders() {
    var upstream = HTTPHeaders()
    upstream.add(name: "content-type", value: "application/problem+json")
    upstream.add(name: "retry-after", value: "15")
    upstream.add(name: "x-request-id", value: "request-123")
    upstream.add(name: "traceparent", value: "00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01")
    upstream.add(name: "x-accel-buffering", value: "no")
    upstream.add(name: "connection", value: "close")

    let headers = OperationsProxyRoutes.responseHeaders(from: upstream)
    #expect(headers[.contentType] == "application/problem+json")
    #expect(headers[HTTPField.Name("retry-after")!] == "15")
    #expect(headers[HTTPField.Name("x-request-id")!] == "request-123")
    #expect(headers[HTTPField.Name("traceparent")!] != nil)
    #expect(headers[HTTPField.Name("x-accel-buffering")!] == "no")
    #expect(headers[HTTPField.Name("connection")!] == nil)
  }

  @Test("operations proxy forwards the mutation idempotency key")
  func operationsProxyIdempotencyKey() {
    var headers = HTTPFields()
    headers[HTTPField.Name("Idempotency-Key")!] = "mutation-123"
    #expect(OperationsProxyRoutes.idempotencyKey(from: headers) == "mutation-123")
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
