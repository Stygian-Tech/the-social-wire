import Testing

@testable import ThinAppViewCore

@Suite("Tap message retry")
struct TapMessageRetryTests {
  @Test func retriesTransientMessageFailuresWithoutReconnecting() async throws {
    let attempts = TapMessageAttemptCounter(failuresBeforeSuccess: 2)

    try await TapMessageRetry.run(delays: [.zero, .zero]) {
      try await attempts.run()
    }

    #expect(await attempts.count == 3)
  }

  @Test func rethrowsAfterRetryBudgetIsExhausted() async {
    let attempts = TapMessageAttemptCounter(failuresBeforeSuccess: .max)

    await #expect(throws: TapMessageRetryTestError.failed) {
      try await TapMessageRetry.run(delays: [.zero, .zero]) {
        try await attempts.run()
      }
    }

    #expect(await attempts.count == 3)
  }
}

private actor TapMessageAttemptCounter {
  private let failuresBeforeSuccess: Int
  private(set) var count = 0

  init(failuresBeforeSuccess: Int) {
    self.failuresBeforeSuccess = failuresBeforeSuccess
  }

  func run() throws {
    count += 1
    if count <= failuresBeforeSuccess {
      throw TapMessageRetryTestError.failed
    }
  }
}

private enum TapMessageRetryTestError: Error {
  case failed
}
