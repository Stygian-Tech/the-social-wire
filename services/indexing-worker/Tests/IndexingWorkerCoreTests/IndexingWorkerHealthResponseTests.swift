import NIOHTTP1
import Testing
@testable import IndexingWorkerCore

@Suite("Indexing worker health responses")
struct IndexingWorkerHealthResponseTests {
  @Test("liveness remains independent of dependency probes")
  func liveness() async {
    let response = await IndexingWorkerHealthResponseBuilder.response(
      method: .GET,
      uri: "/livez",
      role: .projection,
      startupProbe: { throw ProbeError.unavailable },
      readinessProbe: { throw ProbeError.unavailable }
    )

    #expect(response.status == .ok)
    #expect(response.body.contains(#""role":"projection""#))
  }

  @Test("startup and readiness fail closed independently")
  func probes() async {
    let starting = await IndexingWorkerHealthResponseBuilder.response(
      method: .GET,
      uri: "/startupz",
      role: .coordinator,
      startupProbe: {},
      readinessProbe: { throw ProbeError.unavailable }
    )
    #expect(starting.status == .ok)

    let unavailable = await IndexingWorkerHealthResponseBuilder.response(
      method: .GET,
      uri: "/readyz",
      role: .coordinator,
      startupProbe: {},
      readinessProbe: { throw ProbeError.unavailable }
    )
    #expect(unavailable.status == .serviceUnavailable)
    #expect(unavailable.body.contains(#""status":"unavailable""#))
  }
}

private enum ProbeError: Error {
  case unavailable
}
