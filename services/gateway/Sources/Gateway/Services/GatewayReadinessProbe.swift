import AsyncHTTPClient
import Foundation
import OperationsCore

struct GatewayReadinessProbe: Sendable {
  let operationsStore: (any OperationsStore)?
  let appViewBaseURL: String?
  let charybdisBaseURL: String?
  let checkDependency: @Sendable (String) async throws -> Void

  init(
    operationsStore: (any OperationsStore)?,
    appViewBaseURL: String?,
    charybdisBaseURL: String?,
    httpClient: HTTPClient
  ) {
    self.operationsStore = operationsStore
    self.appViewBaseURL = appViewBaseURL
    self.charybdisBaseURL = charybdisBaseURL
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
    operationsStore: (any OperationsStore)? = nil,
    appViewBaseURL: String?,
    charybdisBaseURL: String?,
    checkDependency: @escaping @Sendable (String) async throws -> Void
  ) {
    self.operationsStore = operationsStore
    self.appViewBaseURL = appViewBaseURL
    self.charybdisBaseURL = charybdisBaseURL
    self.checkDependency = checkDependency
  }

  func run() async throws {
    try await operationsStore?.ping()

    try await checkRequiredDependency(name: "appview", baseURL: appViewBaseURL)
    try await checkRequiredDependency(name: "charybdis", baseURL: charybdisBaseURL)
  }

  private func checkRequiredDependency(name: String, baseURL: String?) async throws {
    guard let baseURL else {
      throw GatewayReadinessError.dependencyNotConfigured(name: name)
    }
    let normalized = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !normalized.isEmpty else {
      throw GatewayReadinessError.dependencyNotConfigured(name: name)
    }
    try await checkDependency(normalized)
  }
}

enum GatewayReadinessError: Error, Equatable {
  case dependencyNotConfigured(name: String)
  case dependencyUnavailable(status: UInt)
}
