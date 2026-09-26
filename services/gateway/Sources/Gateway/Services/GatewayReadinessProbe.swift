import AsyncHTTPClient
import Foundation
import OperationsCore

enum GatewayReadinessDependency: String, CaseIterable, Equatable, Sendable {
  case database
  case appview
}

struct GatewayReadinessProbe: Sendable {
  let checkDatabase: @Sendable () async throws -> Void
  let appViewBaseURL: String?
  let checkDependency: @Sendable (String) async throws -> Void
  let recordFailure: @Sendable (GatewayReadinessDependency) async -> Void

  init(
    operationsStore: (any OperationsStore)?,
    appViewBaseURL: String?,
    httpClient: HTTPClient,
    recordFailure: @escaping @Sendable (GatewayReadinessDependency) async -> Void = { _ in }
  ) {
    self.checkDatabase = {
      guard let operationsStore else {
        throw GatewayReadinessError.dependencyNotConfigured(name: "database")
      }
      try await operationsStore.ping()
    }
    self.appViewBaseURL = appViewBaseURL
    self.recordFailure = recordFailure
    self.checkDependency = { baseURL in
      let status = try await GatewayDependencyHTTPProbe.status(baseURL: baseURL, httpClient: httpClient)
      guard (200..<300).contains(Int(status)) else {
        throw GatewayReadinessError.dependencyUnavailable(status: status)
      }
    }
  }

  init(
    checkDatabase: @escaping @Sendable () async throws -> Void = {},
    appViewBaseURL: String?,
    checkDependency: @escaping @Sendable (String) async throws -> Void,
    recordFailure: @escaping @Sendable (GatewayReadinessDependency) async -> Void = { _ in }
  ) {
    self.checkDatabase = checkDatabase
    self.appViewBaseURL = appViewBaseURL
    self.checkDependency = checkDependency
    self.recordFailure = recordFailure
  }

  func run() async throws {
    try await check(.database, operation: checkDatabase)

    try await checkRequiredDependency(.appview, baseURL: appViewBaseURL)
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
      try Task.checkCancellation()
      if error is CancellationError { throw error }
      await recordFailure(dependency)
      throw error
    }
  }
}

enum GatewayReadinessError: Error, Equatable {
  case dependencyNotConfigured(name: String)
  case dependencyUnavailable(status: UInt)
}
