import AsyncHTTPClient
import Foundation
import Logging
import NIOCore
import NIOHTTP1

public protocol TapRepositoryAdminClient: Sendable {
  func addRepositories(_ dids: [String]) async throws
  func removeRepositories(_ dids: [String]) async throws
}

protocol TapRepositoryAdminHTTPTransport: Sendable {
  func execute(_ request: HTTPClientRequest, timeout: TimeAmount) async throws
    -> HTTPClientResponse
}

private struct LiveTapRepositoryAdminHTTPTransport: TapRepositoryAdminHTTPTransport, Sendable {
  let httpClient: HTTPClient

  func execute(_ request: HTTPClientRequest, timeout: TimeAmount) async throws
    -> HTTPClientResponse
  {
    try await httpClient.execute(request, timeout: timeout)
  }
}

public struct HTTPTapRepositoryAdminClient: TapRepositoryAdminClient, Sendable {
  private let transport: any TapRepositoryAdminHTTPTransport
  private let baseURL: URL
  private let adminPassword: String

  public init(httpClient: HTTPClient, baseURL: URL, adminPassword: String) {
    self.init(
      transport: LiveTapRepositoryAdminHTTPTransport(httpClient: httpClient),
      baseURL: baseURL,
      adminPassword: adminPassword
    )
  }

  init(
    transport: any TapRepositoryAdminHTTPTransport,
    baseURL: URL,
    adminPassword: String
  ) {
    self.transport = transport
    self.baseURL = baseURL
    self.adminPassword = adminPassword
  }

  public func addRepositories(_ dids: [String]) async throws {
    try await submit(dids, path: "repos/add")
  }

  public func removeRepositories(_ dids: [String]) async throws {
    try await submit(dids, path: "repos/remove")
  }

  private func submit(_ dids: [String], path: String) async throws {
    guard !dids.isEmpty else { return }
    let url = baseURL.appendingPathComponent(path)
    var request = HTTPClientRequest(url: url.absoluteString)
    request.method = .POST
    request.headers.add(name: "Content-Type", value: "application/json")
    request.headers.add(name: "Authorization", value: basicAuthorization())
    request.body = .bytes(try JSONSerialization.data(withJSONObject: ["dids": dids]))
    let response = try await transport.execute(request, timeout: .seconds(30))
    let statusCode = Int(response.status.code)
    try await HTTPResponseBodyDrain.drainOrCancel(response.body)
    guard (200..<300).contains(statusCode) else {
      throw TapRepositoryTrackerError.rejected(statusCode: statusCode)
    }
  }

  private func basicAuthorization() -> String {
    let encoded = Data("admin:\(adminPassword)".utf8).base64EncodedString()
    return "Basic \(encoded)"
  }
}

/// Reconciles Tap's registered repositories to the current durable AppView publication scope.
///
/// Registration state is persisted after Tap accepts each chunk, so restart does not widen scope.
/// A genuine unsubscribe calls `/repos/remove`; re-enrollment later calls `/repos/add` and Tap runs
/// its normal pending repository sync. Removal is never used as an operator resync mechanism.
public actor TapRepositoryTracker {
  private let store: any ThinAppViewStore
  private let adminClient: any TapRepositoryAdminClient
  private let configuration: TapConsumerConfiguration
  private let logger: Logger

  public init(
    store: any ThinAppViewStore,
    httpClient: HTTPClient,
    configuration: TapConsumerConfiguration,
    logger: Logger
  ) {
    self.init(
      store: store,
      adminClient: HTTPTapRepositoryAdminClient(
        httpClient: httpClient,
        baseURL: configuration.baseURL,
        adminPassword: configuration.adminPassword
      ),
      configuration: configuration,
      logger: logger
    )
  }

  public init(
    store: any ThinAppViewStore,
    adminClient: any TapRepositoryAdminClient,
    configuration: TapConsumerConfiguration,
    logger: Logger
  ) {
    self.store = store
    self.adminClient = adminClient
    self.configuration = configuration
    self.logger = logger
  }

  public func runForever() async {
    guard configuration.mode != .disabled else { return }
    while !Task.isCancelled {
      do {
        _ = try await runOnce()
      } catch {
        logger.warning(
          "Tap repository boundary sync failed",
          metadata: ["error_type": .string(String(describing: type(of: error)))]
        )
      }
      try? await Task.sleep(for: .seconds(configuration.repoSyncIntervalSeconds))
    }
  }

  @discardableResult
  public func runOnce() async throws -> TapRepositoryReconciliationResult {
    let scope = try await store.desiredTapRepositoryScope(limit: configuration.repoSyncLimit)
    guard !scope.truncated else {
      throw TapRepositoryTrackerError.desiredScopeTruncated(limit: configuration.repoSyncLimit)
    }
    let desired = Set(scope.repoDids)
    let registered = Set(
      try await store.registeredTapRepositoryDids(environment: configuration.environment)
    )
    let additions = desired.subtracting(registered).sorted()
    let removals = registered.subtracting(desired).sorted()

    for chunk in Self.chunks(additions) {
      try await adminClient.addRepositories(chunk)
      try await store.markTapRepositoriesRegistered(
        environment: configuration.environment,
        repoDids: chunk,
        at: Date()
      )
    }
    for chunk in Self.chunks(removals) {
      try await adminClient.removeRepositories(chunk)
      try await store.markTapRepositoriesRemoved(
        environment: configuration.environment,
        repoDids: chunk,
        at: Date()
      )
    }
    return TapRepositoryReconciliationResult(
      desiredCount: desired.count,
      added: additions,
      removed: removals
    )
  }

  private static func chunks(_ values: [String]) -> [[String]] {
    stride(from: 0, to: values.count, by: 100).map { start in
      Array(values[start..<min(values.count, start + 100)])
    }
  }
}

public struct TapRepositoryReconciliationResult: Sendable, Equatable {
  public let desiredCount: Int
  public let added: [String]
  public let removed: [String]
}

public enum TapRepositoryTrackerError: Error, Equatable {
  case rejected(statusCode: Int)
  case desiredScopeTruncated(limit: Int)
}
