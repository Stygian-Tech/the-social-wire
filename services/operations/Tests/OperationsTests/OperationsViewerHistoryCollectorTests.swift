import Foundation
import Testing
@testable import Operations

@Test("viewer history collects on startup and repeats hourly without dashboard requests")
func viewerHistoryCollectsIndependently() async {
  let state = ViewerHistoryCollectionState()
  let collector = OperationsViewerHistoryCollector(
    collect: { _ in await state.collected() },
    sleep: { duration in
      #expect(duration == .seconds(3_600))
      if await state.count == 2 { throw CancellationError() }
    })

  await collector.runForever()
  #expect(await state.count == 2)
}

@Test("viewer history stops promptly when cancelled during its hourly sleep")
func viewerHistoryCancellationStopsSleep() async {
  let state = ViewerHistoryCollectionState()
  let collector = OperationsViewerHistoryCollector(
    collect: { _ in await state.collected() },
    sleep: { duration in
      await state.signalSleeping()
      try await Task.sleep(for: duration)
    })
  let running = Task { await collector.runForever() }
  await state.waitUntilSleeping()
  running.cancel()
  await running.value
  #expect(await state.count == 1)
}

@Test("viewer history does not sample an already cancelled task")
func viewerHistoryDoesNotStartWhenCancelled() async {
  let collector = OperationsViewerHistoryCollector(collect: { _ in
    Issue.record("Cancelled task must not collect viewer history")
  })
  await Task {
    withUnsafeCurrentTask { $0?.cancel() }
    await collector.runForever()
  }.value
}

private actor ViewerHistoryCollectionState {
  private(set) var count = 0
  private var sleeping = false
  private var observer: CheckedContinuation<Void, Never>?

  func collected() { count += 1 }

  func signalSleeping() {
    sleeping = true
    observer?.resume()
    observer = nil
  }

  func waitUntilSleeping() async {
    if sleeping { return }
    await withCheckedContinuation { observer = $0 }
  }
}
