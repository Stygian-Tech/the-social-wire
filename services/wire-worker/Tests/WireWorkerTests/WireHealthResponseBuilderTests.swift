import NIOHTTP1
import Testing
@testable import WireWorkerCore

@Suite("The Wire worker health responses")
struct WireHealthResponseBuilderTests {
  private enum ProbeError: Error { case unavailable }

  @Test("startup verifies Postgres")
  func startup() async {
    let response = await WireHealthResponseBuilder.response(
      method: .GET,
      uri: "/startupz?edge=true",
      databaseProbe: {}
    )
    #expect(response.status == .ok)
  }

  @Test("readiness fails closed when Postgres is unavailable")
  func unavailable() async {
    let response = await WireHealthResponseBuilder.response(
      method: .GET,
      uri: "/readyz",
      databaseProbe: { throw ProbeError.unavailable }
    )
    #expect(response.status == .serviceUnavailable)
  }

  @Test("readiness fails closed when generation cycles are stale")
  func staleCycle() async {
    let response = await WireHealthResponseBuilder.response(
      method: .GET,
      uri: "/readyz",
      databaseProbe: {},
      readinessProbe: { throw ProbeError.unavailable }
    )
    #expect(response.status == .serviceUnavailable)
  }

  @Test("unknown routes and mutation methods are rejected")
  func routing() async {
    let missing = await WireHealthResponseBuilder.response(method: .GET, uri: "/nope", databaseProbe: {})
    let mutation = await WireHealthResponseBuilder.response(method: .POST, uri: "/readyz", databaseProbe: {})
    #expect(missing.status == .notFound)
    #expect(mutation.status == .methodNotAllowed)
  }
}
