import Foundation
import OperationsCore
import Testing
@testable import Operations

@Test func databaseCostCollectorSamplesImmediatelyAndIncludesCollectionTime() async {
  let timeline = DatabaseCostTestTimeline(work: [.seconds(2), .seconds(5)])
  let collector = OperationsDatabaseCostCollector(
    groups: [.counters],
    collect: { _, _ in timeline.collect() },
    now: { timeline.now() },
    sleep: { try timeline.sleep($0) })

  await collector.runForever()

  #expect(timeline.starts == [.zero, .seconds(60)])
  #expect(timeline.sleeps == [.seconds(58), .seconds(55)])
}

@Test func databaseCostCollectorDoesNotCatchUpOrOverlapSlowPasses() async {
  let timeline = DatabaseCostTestTimeline(work: [.seconds(75), .seconds(2)])
  let collector = OperationsDatabaseCostCollector(
    groups: [.counters],
    collect: { _, _ in timeline.collect() },
    now: { timeline.now() },
    sleep: { try timeline.sleep($0) })

  await collector.runForever()

  #expect(timeline.starts == [.zero, .seconds(135)])
  #expect(timeline.sleeps == [.seconds(60), .seconds(58)])
}

@Test func databaseCostCollectorRejectsDuplicateLoopAndStopsAfterCancelledPass() async {
  let gate = DatabaseCostCollectionGate()
  let collector = OperationsDatabaseCostCollector(
    groups: [.counters],
    collect: { _, _ in await gate.collect() },
    sleep: { _ in Issue.record("Cancelled collection must not schedule another pass") })
  let running = Task { await collector.runForever() }
  await gate.waitUntilStarted()

  // The first pass is suspended: a second entry must return without sampling.
  await collector.runForever()
  #expect(await gate.count == 1)
  running.cancel()
  await gate.release()
  await running.value
  #expect(await gate.count == 1)

  // Cancellation releases lifecycle ownership so a later service run can start again.
  let restarted = Task {
    await collector.runForever()
  }
  await gate.waitUntilStarted()
  restarted.cancel()
  await gate.release()
  await restarted.value
  #expect(await gate.count == 2)
}

@Test func databaseCostCollectorCancellationInterruptsMinuteSleep() async {
  let sleeping = DatabaseCostCollectionGate()
  let timeline = DatabaseCostTestTimeline(work: [.zero])
  let collector = OperationsDatabaseCostCollector(
    groups: [.counters],
    collect: { _, _ in timeline.collect() },
    sleep: { duration in
      await sleeping.signalStarted()
      try await Task.sleep(for: duration)
    })
  let running = Task { await collector.runForever() }
  await sleeping.waitUntilStarted()
  running.cancel()
  await running.value
  #expect(timeline.starts.count == 1)
}

@Test func databaseCostCollectorDoesNotSampleAnAlreadyCancelledTask() async {
  let timeline = DatabaseCostTestTimeline(work: [.zero])
  let collector = OperationsDatabaseCostCollector(groups: [.counters], collect: { _, _ in timeline.collect() })
  await Task {
    withUnsafeCurrentTask { $0?.cancel() }
    await collector.runForever()
  }.value
  #expect(timeline.starts.isEmpty)
}


@Test(arguments: DatabaseCostTelemetryGroup.allCases)
func databaseCostCollectorUsesIndependentCadences(group: DatabaseCostTelemetryGroup) async {
  let timeline = DatabaseCostTestTimeline(work: [.seconds(2), .seconds(5)])
  let collector = OperationsDatabaseCostCollector(
    groups: [group],
    collect: { actualGroup, at in
      #expect(actualGroup == group)
      timeline.collect(at: at)
    },
    now: { timeline.now() },
    observedAt: { timeline.observedAt() },
    sleep: { try timeline.sleep($0) })
  await collector.runForever()
  let interval = Duration.seconds(group.intervalSeconds)
  #expect(timeline.starts == [.zero, interval])
  #expect(timeline.sleeps == [interval - .seconds(2), interval - .seconds(5)])
  #expect(timeline.dates == [Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: group.intervalSeconds)])
}

@Test func databaseCostCollectorBlockedTablesDoNotDelayCounters() async {
  let counters = DatabaseCostCollectionGate()
  let tables = DatabaseCostCollectionGate()
  let collector = OperationsDatabaseCostCollector(
    groups: [.counters, .tables],
    collect: { group, _ in
      switch group {
      case .counters: await counters.collect()
      case .tables: await tables.collect()
      default: Issue.record("Unexpected schedule")
      }
    },
    sleep: { _ in })
  let running = Task { await collector.runForever() }
  await tables.waitUntilStarted()
  await counters.waitUntilStarted()
  await counters.release()
  await counters.waitUntilStarted()
  #expect(await counters.count == 2)
  #expect(await tables.count == 1)
  running.cancel()
  await counters.release()
  await tables.release()
  await running.value
}

/// Synchronous clock reads require a lock; all mutable test state stays behind it.
private final class DatabaseCostTestTimeline: @unchecked Sendable {
  private let lock = NSLock()
  private let origin = ContinuousClock.now
  private let work: [Duration]
  private var elapsed: Duration = .zero
  private var recordedStarts: [Duration] = []
  private var recordedSleeps: [Duration] = []
  private var recordedDates: [Date] = []

  init(work: [Duration]) { self.work = work }

  var starts: [Duration] { lock.withLock { recordedStarts } }
  var sleeps: [Duration] { lock.withLock { recordedSleeps } }
  var dates: [Date] { lock.withLock { recordedDates } }
  func observedAt() -> Date { lock.withLock { Date(timeIntervalSince1970: elapsed / .seconds(1)) } }
  func now() -> ContinuousClock.Instant { lock.withLock { origin.advanced(by: elapsed) } }

  func collect(at: Date? = nil) {
    lock.withLock {
      if let at { recordedDates.append(at) }
      let index = recordedStarts.count
      recordedStarts.append(elapsed)
      if index < work.count { elapsed += work[index] }
    }
  }

  func sleep(_ duration: Duration) throws {
    try lock.withLock {
      recordedSleeps.append(duration)
      if recordedSleeps.count >= work.count { throw CancellationError() }
      elapsed += duration
    }
  }
}

private actor DatabaseCostCollectionGate {
  private(set) var count = 0
  private var started = false
  private var observer: CheckedContinuation<Void, Never>?
  private var continuation: CheckedContinuation<Void, Never>?

  func collect() async {
    count += 1
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      signalStarted()
    }
  }

  func signalStarted() {
    started = true
    observer?.resume()
    observer = nil
  }

  func waitUntilStarted() async {
    if started { return }
    await withCheckedContinuation { observer = $0 }
  }

  func release() {
    started = false
    continuation?.resume()
    continuation = nil
  }
}
