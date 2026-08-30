import Logging
import Testing
@testable import IndexingWorkerCore

@Suite("Indexing worker component supervision")
struct IndexingWorkerComponentSupervisorTests {
  @Test("restarts a failed lane without exiting the supervisor")
  func restartsFailedLane() async throws {
    let attempts = AttemptCounter()
    let state = IndexingWorkerLaneState()
    let task = Task {
      try await IndexingWorkerComponentSupervisor.run(
        lane: .appView,
        state: state,
        logger: Logger(label: "indexing-worker-supervisor-tests")
      ) {
        let attempt = await attempts.increment()
        if attempt == 1 {
          throw TestFailure.expected
        }
        try await Task.sleep(for: .seconds(30))
      }
    }

    try await waitUntil(timeout: .seconds(2)) {
      await attempts.value >= 2
    }

    #expect(await state.phase(for: .appView) == .running)
    task.cancel()
    await #expect(throws: CancellationError.self) {
      try await task.value
    }
  }

  private func waitUntil(
    timeout: Duration,
    condition: @Sendable () async -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for the supervised lane to restart")
  }
}

private actor AttemptCounter {
  private(set) var value = 0

  func increment() -> Int {
    value += 1
    return value
  }
}

private enum TestFailure: Error {
  case expected
}
