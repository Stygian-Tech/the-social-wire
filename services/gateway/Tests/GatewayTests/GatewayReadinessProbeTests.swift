import Testing

@testable import Gateway

@Suite("Gateway readiness probe")
struct GatewayReadinessProbeTests {
  @Test("configured AppView readiness is required")
  func checksAppView() async throws {
    let recorder = AppViewProbeRecorder()
    let probe = GatewayReadinessProbe(
      appViewBaseURL: "http://appview.railway.internal:8081/",
      projectionPoolBaseURL: "http://projection-pool.railway.internal:8080/",
      checkDependency: { baseURL in await recorder.record(baseURL) }
    )

    try await probe.run()
    #expect(await recorder.baseURLs == [
      "http://appview.railway.internal:8081",
      "http://projection-pool.railway.internal:8080",
    ])
  }

  @Test("an AppView readiness failure fails Gateway readiness")
  func propagatesAppViewFailure() async {
    let recorder = ReadinessFailureRecorder()
    let probe = GatewayReadinessProbe(
      appViewBaseURL: "http://appview.railway.internal:8081",
      projectionPoolBaseURL: "http://projection-pool.railway.internal:8080",
      checkDependency: { _ in throw ProbeError.unavailable },
      recordFailure: { dependency in await recorder.record(dependency) }
    )

    await #expect(throws: ProbeError.self) {
      try await probe.run()
    }
    #expect(await recorder.dependencies == [.appview])
  }

  @Test("readiness failures identify database, AppView, and Projection Pool")
  func attributesRequiredDependencyFailures() async {
    for failedDependency in GatewayReadinessDependency.allCases {
      let recorder = ReadinessFailureRecorder()
      let probe = GatewayReadinessProbe(
        checkDatabase: {
          if failedDependency == .database { throw ProbeError.unavailable }
        },
        appViewBaseURL: "http://appview.railway.internal:8081",
        projectionPoolBaseURL: "http://projection-pool.railway.internal:8080",
        checkDependency: { baseURL in
          let dependencyToken =
            failedDependency == .projectionPool ? "projection-pool" : failedDependency.rawValue
          if baseURL.contains(dependencyToken) {
            throw ProbeError.unavailable
          }
        },
        recordFailure: { dependency in await recorder.record(dependency) }
      )

      await #expect(throws: ProbeError.self) {
        try await probe.run()
      }
      #expect(await recorder.dependencies == [failedDependency])
    }
  }

  @Test("missing required dependencies fail readiness closed")
  func missingDependency() async {
    let recorder = ReadinessFailureRecorder()
    let probe = GatewayReadinessProbe(
      appViewBaseURL: nil,
      projectionPoolBaseURL: "http://projection-pool.railway.internal:8080",
      checkDependency: { _ in },
      recordFailure: { dependency in await recorder.record(dependency) }
    )

    await #expect(throws: GatewayReadinessError.dependencyNotConfigured(name: "appview")) {
      try await probe.run()
    }
    #expect(await recorder.dependencies == [.appview])
  }
}

private actor AppViewProbeRecorder {
  private(set) var baseURLs: [String] = []

  func record(_ baseURL: String) {
    baseURLs.append(baseURL)
  }
}

private actor ReadinessFailureRecorder {
  private(set) var dependencies: [GatewayReadinessDependency] = []

  func record(_ dependency: GatewayReadinessDependency) {
    dependencies.append(dependency)
  }
}

private enum ProbeError: Error {
  case unavailable
}
