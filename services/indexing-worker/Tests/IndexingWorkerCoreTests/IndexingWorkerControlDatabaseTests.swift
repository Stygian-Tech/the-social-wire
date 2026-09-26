import Logging
import Testing
@testable import IndexingWorkerCore

@Suite("Indexing worker connection ownership")
struct IndexingWorkerControlDatabaseTests {
  @Test("Projection does not construct or validate a wrapper database pool")
  func projectionHasNoControlPool() throws {
    let control = try IndexingWorkerControlDatabase.make(
      role: .projection, databaseURL: "unused-invalid-url", environment: [:],
      appEnvironment: "test", logger: Logger(label: "indexing.tests"))
    #expect(control == nil)
  }
  @Test("Projection health probes both existing component pools and propagates failure")
  func componentReadiness() async throws {
    let state = IndexingWorkerLaneState()
    await state.set(.running, for: .appView)
    await state.set(.running, for: .wire)
    let visited = ProbeRecorder()
    try await IndexingWorkerRuntime.probeLanes(role: .projection, state: state) {
      await visited.record($0)
    }
    #expect(await visited.lanes == [.appView, .wire])
    await #expect(throws: ComponentProbeFailure.self) {
      try await IndexingWorkerRuntime.probeLanes(role: .projection, state: state) { lane in
        if lane == .wire { throw ComponentProbeFailure.unavailable }
      }
    }
    await state.set(.restarting, for: .appView)
    await #expect(throws: IndexingWorkerHealthError.self) {
      try await IndexingWorkerRuntime.probeLanes(role: .projection, state: state) { _ in }
    }
  }

}


private actor ProbeRecorder {
  var lanes: [IndexingWorkerLane] = []
  func record(_ lane: IndexingWorkerLane) { lanes.append(lane) }
}

private enum ComponentProbeFailure: Error { case unavailable }
