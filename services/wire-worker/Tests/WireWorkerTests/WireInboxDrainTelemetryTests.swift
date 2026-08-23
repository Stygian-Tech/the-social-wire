import Foundation
import Logging
import Testing
@testable import WireWorker

@Suite("The Wire drain interval telemetry")
struct WireInboxDrainTelemetryTests {
  private enum TestError: Error { case unavailable }

  @Test("interval aggregation reports applied throughput and resets")
  func intervalAggregation() async {
    let startedAt = Date(timeIntervalSince1970: 2_000_000_000)
    let telemetry = WireInboxDrainTelemetryState(startedAt: startedAt)
    await telemetry.recordAppliedEvents(60)
    await telemetry.recordAppliedEvents(30)

    let first = await telemetry.finishInterval(
      at: startedAt.addingTimeInterval(60),
      backlog: .init(actionableEventCount: 4_200, oldestActionableAgeSeconds: 75)
    )
    #expect(first.intervalSeconds == 60)
    #expect(first.appliedEventCount == 90)
    #expect(first.appliedEventsPerSecond == 1.5)
    #expect(first.backlog.actionableEventCount == 4_200)
    #expect(first.backlog.oldestActionableAgeSeconds == 75)

    let second = await telemetry.finishInterval(
      at: startedAt.addingTimeInterval(120),
      backlog: .init(actionableEventCount: 0, oldestActionableAgeSeconds: nil)
    )
    #expect(second.appliedEventCount == 0)
    #expect(second.appliedEventsPerSecond == 0)
  }

  @Test("zero backlog emits a complete info-level interval")
  func zeroBacklog() async throws {
    let startedAt = Date(timeIntervalSince1970: 2_000_000_000)
    let telemetry = WireInboxDrainTelemetryState(startedAt: startedAt)
    let observer = TelemetryBacklogObserver(outcomes: [
      .success(.init(actionableEventCount: 0, oldestActionableAgeSeconds: nil))
    ])
    let logs = TelemetryLogStore()
    var logger = Logger(label: "wire-drain-telemetry.test") { _ in
      TelemetryLogHandler(store: logs)
    }
    logger.logLevel = .info

    try await WireInboxDrainTelemetryRuntime.run(
      observer: observer,
      telemetry: telemetry,
      logger: logger,
      configuration: .init(intervalMilliseconds: 60_000),
      clock: TelemetryClock(dates: [
        startedAt.addingTimeInterval(60), startedAt.addingTimeInterval(60),
      ]),
      sleeper: TelemetrySleeper(),
      iterationLimit: 1
    )

    let event = try #require(logs.events().first)
    #expect(event.level == .info)
    #expect(event.message == "The Wire drain interval health")
    #expect(event.metadata["applied_event_count"] == "0")
    #expect(event.metadata["applied_events_per_second"] == "0.0")
    #expect(event.metadata["actionable_backlog_count"] == "0")
    #expect(event.metadata["actionable_backlog_oldest_age_seconds"] == "none")
    #expect(await observer.callCount == 1)
  }

  @Test("failed backlog snapshots preserve counts and do not escape the reporter")
  func failedSnapshot() async throws {
    let startedAt = Date(timeIntervalSince1970: 2_000_000_000)
    let telemetry = WireInboxDrainTelemetryState(startedAt: startedAt)
    await telemetry.recordAppliedEvents(45)
    let observer = TelemetryBacklogObserver(outcomes: [.failure(TestError.unavailable)])
    let logs = TelemetryLogStore()
    var logger = Logger(label: "wire-drain-telemetry.test") { _ in
      TelemetryLogHandler(store: logs)
    }
    logger.logLevel = .info

    try await WireInboxDrainTelemetryRuntime.run(
      observer: observer,
      telemetry: telemetry,
      logger: logger,
      clock: TelemetryClock(dates: [startedAt.addingTimeInterval(60)]),
      sleeper: TelemetrySleeper(),
      iterationLimit: 1
    )

    let event = try #require(logs.events().first)
    #expect(event.level == .warning)
    #expect(event.message == "The Wire drain backlog snapshot unavailable")
    #expect(event.metadata == ["telemetry_error": "backlog_snapshot_failed"])

    let recovered = await telemetry.finishInterval(
      at: startedAt.addingTimeInterval(90),
      backlog: .init(actionableEventCount: 12, oldestActionableAgeSeconds: 3)
    )
    #expect(recovered.appliedEventCount == 45)
    #expect(recovered.appliedEventsPerSecond == 0.5)
  }
}

private actor TelemetryBacklogObserver: WireInboxBacklogObserving {
  enum Outcome: Sendable {
    case success(WireInboxBacklogHealth)
    case failure(any Error & Sendable)
  }

  private var outcomes: [Outcome]
  private(set) var callCount = 0

  init(outcomes: [Outcome]) { self.outcomes = outcomes }

  func actionableBacklogHealth(asOf: Date) throws -> WireInboxBacklogHealth {
    callCount += 1
    switch outcomes.removeFirst() {
    case .success(let health): return health
    case .failure(let error): throw error
    }
  }
}

private actor TelemetryClock: WireInboxDrainClock {
  private var dates: [Date]
  init(dates: [Date]) { self.dates = dates }
  func now() -> Date { dates.removeFirst() }
}

private actor TelemetrySleeper: WireInboxDrainSleeping {
  func sleep(milliseconds: Int) {}
}

private struct RecordedTelemetryLog: Sendable {
  let level: Logger.Level
  let message: String
  let metadata: [String: String]
}

private final class TelemetryLogStore: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedEvents: [RecordedTelemetryLog] = []

  func append(_ event: LogEvent) {
    lock.lock()
    recordedEvents.append(
      RecordedTelemetryLog(
        level: event.level,
        message: event.message.description,
        metadata: event.metadata?.mapValues(\.description) ?? [:]
      )
    )
    lock.unlock()
  }

  func events() -> [RecordedTelemetryLog] {
    lock.lock()
    defer { lock.unlock() }
    return recordedEvents
  }
}

private struct TelemetryLogHandler: LogHandler {
  var metadataProvider: Logger.MetadataProvider?
  var metadata: Logger.Metadata = [:]
  var logLevel: Logger.Level = .info
  let store: TelemetryLogStore

  subscript(metadataKey key: String) -> Logger.Metadata.Value? {
    get { metadata[key] }
    set { metadata[key] = newValue }
  }

  func log(event: LogEvent) {
    store.append(event)
  }
}
