import Hummingbird
import Testing
@testable import AppView

@Suite("AppView feed error classification")
struct AppViewFeedErrorTests {
  @Test("request errors keep their status and are not retryable")
  func requestErrorClassification() {
    let error = AppViewFeedErrorClassifier.classify(
      HTTPError(.badRequest, message: "Invalid cursor"),
      requestId: "req-400"
    )
    #expect(error.status == .badRequest)
    #expect(error.code == "invalid_request")
    #expect(error.requestId == "req-400")
    #expect(error.retryable == false)
  }

  @Test("connection failures are transient and retryable")
  func transientClassification() {
    let error = AppViewFeedErrorClassifier.classify(
      StubConnectionPoolError(),
      requestId: "req-503"
    )
    #expect(error.status == .serviceUnavailable)
    #expect(error.code == "feed_dependency_unavailable")
    #expect(error.retryable)
  }

  @Test("bounded retry succeeds once and never loops")
  func boundedRetry() async throws {
    let attempts = AttemptCounter()
    let value: String = try await AppViewFeedExecution.run(requestId: "req-retry") {
      let attempt = await attempts.next()
      if attempt == 1 {
        throw StubConnectionPoolError()
      }
      return "ok"
    }
    #expect(value == "ok")
    #expect(await attempts.value == 2)
  }

  @Test("cursor and numeric validation fail before feed work")
  func requestValidation() {
    #expect(throws: AppViewFeedError.self) {
      _ = try ThinAppViewRoutes.validatedCursor("not-a-cursor", requestId: "req-cursor")
    }
    #expect(throws: AppViewFeedError.self) {
      _ = try ThinAppViewRoutes.validatedInteger(
        "0",
        name: "limit",
        defaultValue: 50,
        range: 1...100,
        requestId: "req-limit"
      )
    }
    #expect(throws: AppViewFeedError.self) {
      _ = try ThinAppViewRoutes.validatedOptionalInteger(
        "not-a-number",
        name: "maxEntries",
        range: 1...500,
        requestId: "req-max"
      )
    }
  }
}

private struct StubConnectionPoolError: Error {}

private actor AttemptCounter {
  private(set) var value = 0

  func next() -> Int {
    value += 1
    return value
  }
}
