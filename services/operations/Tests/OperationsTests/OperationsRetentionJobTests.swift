import Foundation
import Logging
import Testing
@testable import Operations

@Suite("Adaptive Operations retention")
struct OperationsRetentionJobTests {
  @Test("A full ten-call round continues after one second instead of stranding expired rows")
  func catchesUp() async {
    let recorder = RetentionRecorder(results: Array(repeating: 1_000, count: 10))
    await makeJob(recorder).runForever()
    #expect(await recorder.batchSizes == Array(repeating: 1_000, count: 10))
    #expect(await recorder.delays == [.seconds(1)])
  }

  @Test("Only an observed zero-delete result starts the hourly idle interval")
  func drainsThenIdles() async {
    let recorder = RetentionRecorder(results: [1_000, 20, 0])
    await makeJob(recorder).runForever()
    #expect(await recorder.batchSizes.count == 3)
    #expect(await recorder.delays == [.seconds(3_600)])
  }

  @Test("Failures back off to sixty seconds and successful cleanup resets the retry budget")
  func retries() async {
    let recorder = RetentionRecorder(
      results: [-1, -1, -1, -1, -1, -1, 0, -1], stopAfterSleeps: 8)
    await makeJob(recorder).runForever()
    #expect(await recorder.delays == [5, 10, 20, 40, 60, 60, 3_600, 5].map { .seconds($0) })
  }

  @Test("Cancellation stops without retrying or sleeping")
  func cancellation() async {
    let recorder = RetentionRecorder(results: [-2])
    await makeJob(recorder).runForever()
    #expect(await recorder.batchSizes.count == 1)
    #expect(await recorder.delays.isEmpty)
  }

  @Test("Disabled catch-up preserves the hourly schedule for backlog and failure")
  func rolloutDisabled() async {
    for results in [Array(repeating: 1_000, count: 10), [-1]] {
      let recorder = RetentionRecorder(results: results)
      await makeJob(recorder, catchUpEnabled: false).runForever()
      #expect(await recorder.delays == [.seconds(3_600)])
    }
  }

  @Test("Catch-up is opt-in in the deployed service configuration")
  func configuration() {
    var environment = ["APP_ENV": "dev", "DATABASE_URL": "postgresql://localhost/test"]
    #expect(!OperationsServiceConfig.fromEnvironment(environment).retentionCatchUpEnabled)
    environment["OPERATIONS_RETENTION_CATCHUP_ENABLED"] = "true"
    #expect(OperationsServiceConfig.fromEnvironment(environment).retentionCatchUpEnabled)
    environment["OPERATIONS_RETENTION_CATCHUP_ENABLED"] = "invalid"
    #expect(!OperationsServiceConfig.fromEnvironment(environment).retentionCatchUpEnabled)
  }

  private func makeJob(_ recorder: RetentionRecorder, catchUpEnabled: Bool = true) -> OperationsRetentionJob {
    OperationsRetentionJob(
      cleanup: { try await recorder.cleanup(at: $0, batchSize: $1) },
      logger: Logger(label: "retention.tests"),
      catchUpEnabled: catchUpEnabled,
      now: { Date(timeIntervalSince1970: 1_000) },
      sleep: { try await recorder.sleep($0) })
  }
}

private actor RetentionRecorder {
  var results: [Int]
  var batchSizes: [Int] = []
  var delays: [Duration] = []
  let stopAfterSleeps: Int

  init(results: [Int], stopAfterSleeps: Int = 1) {
    self.results = results
    self.stopAfterSleeps = stopAfterSleeps
  }

  func cleanup(at: Date, batchSize: Int) throws -> Int {
    batchSizes.append(batchSize)
    let value = results.removeFirst()
    if value == -2 { throw CancellationError() }
    if value == -1 { throw RetentionFailure.unavailable }
    return value
  }

  func sleep(_ duration: Duration) throws {
    delays.append(duration)
    if delays.count >= stopAfterSleeps { throw CancellationError() }
  }
}

private enum RetentionFailure: Error { case unavailable }
