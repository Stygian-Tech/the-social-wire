import AsyncHTTPClient
import Foundation
import OperationsCore

enum GatewayReadinessDependency: String, CaseIterable, Equatable, Sendable {
  case database
  case appview
  case charybdis
}

struct GatewayReadinessProbe: Sendable {
  let checkDatabase: @Sendable () async throws -> Void
  let appViewBaseURL: String?
  let charybdisBaseURL: String?
  let checkDependency: @Sendable (String) async throws -> Void
  let recordFailure: @Sendable (GatewayReadinessDependency) async -> Void

  init(
    operationsStore: (any OperationsStore)?,
    appViewBaseURL: String?,
    charybdisBaseURL: String?,
    httpClient: HTTPClient,
    recordFailure: @escaping @Sendable (GatewayReadinessDependency) async -> Void = { _ in }
  ) {
    self.checkDatabase = { try await operationsStore?.ping() }
    self.appViewBaseURL = appViewBaseURL
    self.charybdisBaseURL = charybdisBaseURL
    self.recordFailure = recordFailure
    self.checkDependency = { baseURL in
      var request = HTTPClientRequest(url: "\(baseURL)/readyz")
      request.method = .GET
      let response = try await httpClient.execute(request, timeout: .seconds(5))
      _ = try await response.body.collect(upTo: 4 * 1024)
      guard (200..<300).contains(Int(response.status.code)) else {
        throw GatewayReadinessError.dependencyUnavailable(status: response.status.code)
      }
    }
  }

  init(
    checkDatabase: @escaping @Sendable () async throws -> Void = {},
    appViewBaseURL: String?,
    charybdisBaseURL: String?,
    checkDependency: @escaping @Sendable (String) async throws -> Void,
    recordFailure: @escaping @Sendable (GatewayReadinessDependency) async -> Void = { _ in }
  ) {
    self.checkDatabase = checkDatabase
    self.appViewBaseURL = appViewBaseURL
    self.charybdisBaseURL = charybdisBaseURL
    self.checkDependency = checkDependency
    self.recordFailure = recordFailure
  }

  func run() async throws {
    try await check(.database, operation: checkDatabase)

    try await checkRequiredDependency(.appview, baseURL: appViewBaseURL)
    try await checkRequiredDependency(.charybdis, baseURL: charybdisBaseURL)
  }

  private func checkRequiredDependency(
    _ dependency: GatewayReadinessDependency,
    baseURL: String?
  ) async throws {
    try await check(dependency) {
      guard let baseURL else {
        throw GatewayReadinessError.dependencyNotConfigured(name: dependency.rawValue)
      }
      let normalized = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      guard !normalized.isEmpty else {
        throw GatewayReadinessError.dependencyNotConfigured(name: dependency.rawValue)
      }
      try await checkDependency(normalized)
    }
  }

  private func check(
    _ dependency: GatewayReadinessDependency,
    operation: @Sendable () async throws -> Void
  ) async throws {
    do {
      try await operation()
    } catch {
      await recordFailure(dependency)
      throw error
    }
  }
}

enum GatewayReadinessError: Error, Equatable {
  case dependencyNotConfigured(name: String)
  case dependencyUnavailable(status: UInt)
}
