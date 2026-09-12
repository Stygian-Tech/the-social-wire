import Foundation
import OperationsCore

/// Independent schedules keep expensive scans out of the minute counter sample.
actor OperationsDatabaseCostCollector {
  private let groups: [DatabaseCostTelemetryGroup]
  private let collect: @Sendable (DatabaseCostTelemetryGroup, Date) async -> Void
  private let now: @Sendable () -> ContinuousClock.Instant
  private let observedAt: @Sendable () -> Date
  private let sleep: @Sendable (Duration) async throws -> Void
  private var isRunning = false

  init(
    groups: [DatabaseCostTelemetryGroup] = DatabaseCostTelemetryGroup.allCases,
    collect: @escaping @Sendable (DatabaseCostTelemetryGroup, Date) async -> Void,
    now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
    observedAt: @escaping @Sendable () -> Date = { Date() },
    sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
      try await Task.sleep(for: duration)
    }
  ) {
    self.groups = DatabaseCostTelemetryGroup.allCases.filter { groups.contains($0) }
    self.collect = collect
    self.now = now
    self.observedAt = observedAt
    self.sleep = sleep
  }

  func runForever() async {
    guard !isRunning, !Task.isCancelled else { return }
    isRunning = true
    defer { isRunning = false }
    await withTaskGroup(of: Void.self) { tasks in
      for group in groups {
        tasks.addTask { await self.runSchedule(group) }
      }
      await tasks.waitForAll()
    }
  }

  private func runSchedule(_ group: DatabaseCostTelemetryGroup) async {
    let interval = Duration.seconds(group.intervalSeconds)
    while !Task.isCancelled {
      let started = now()
      await collect(group, observedAt())
      guard !Task.isCancelled else { return }
      let elapsed = started.duration(to: now())
      // Ordinary passes include query/export time. An overrun starts a fresh interval
      // after completion, never launching catch-up samples or overlapping the same group.
      let remaining = elapsed < interval ? interval - elapsed : interval
      do {
        try await sleep(remaining)
      } catch {
        return
      }
    }
  }
}
