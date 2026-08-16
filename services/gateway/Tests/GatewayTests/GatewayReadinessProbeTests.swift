import Testing

@testable import Gateway

@Suite("Gateway readiness probe")
struct GatewayReadinessProbeTests {
  @Test("configured AppView readiness is required")
  func checksAppView() async throws {
    let recorder = AppViewProbeRecorder()
    let probe = GatewayReadinessProbe(
      appViewBaseURL: "http://appview.railway.internal:8081/",
      charybdisBaseURL: "http://charybdis.railway.internal:8082/",
      checkDependency: { baseURL in await recorder.record(baseURL) }
    )

    try await probe.run()
    #expect(await recorder.baseURLs == [
      "http://appview.railway.internal:8081",
      "http://charybdis.railway.internal:8082",
    ])
  }

  @Test("an AppView readiness failure fails Gateway readiness")
  func propagatesAppViewFailure() async {
    let probe = GatewayReadinessProbe(
      appViewBaseURL: "http://appview.railway.internal:8081",
      charybdisBaseURL: "http://charybdis.railway.internal:8082",
      checkDependency: { _ in throw ProbeError.unavailable }
    )

    await #expect(throws: ProbeError.self) {
      try await probe.run()
    }
  }

  @Test("missing required dependencies fail readiness closed")
  func missingDependency() async {
    let probe = GatewayReadinessProbe(
      appViewBaseURL: nil,
      charybdisBaseURL: "http://charybdis.railway.internal:8082",
      checkDependency: { _ in }
    )

    await #expect(throws: GatewayReadinessError.dependencyNotConfigured(name: "appview")) {
      try await probe.run()
    }
  }
}

private actor AppViewProbeRecorder {
  private(set) var baseURLs: [String] = []

  func record(_ baseURL: String) {
    baseURLs.append(baseURL)
  }
}

private enum ProbeError: Error {
  case unavailable
}
