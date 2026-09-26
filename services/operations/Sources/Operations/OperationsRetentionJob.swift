import Foundation
import Logging
import OperationsCore

struct OperationsRetentionJob: Sendable {
  let cleanup: @Sendable (Date, Int) async throws -> Int
  let catchUpEnabled: Bool
  let logger: Logger
  let telemetry: OperationsTelemetryBuffer?
  let now: @Sendable () -> Date
  let sleep: @Sendable (Duration) async throws -> Void

  init(
    store: any OperationsStore, logger: Logger, telemetry: OperationsTelemetryBuffer? = nil,
    catchUpEnabled: Bool = false
  ) {
    self.init(
      cleanup: { try await store.cleanupExpired(at: $0, batchSize: $1) },
      logger: logger, telemetry: telemetry, catchUpEnabled: catchUpEnabled)
  }

  init(
    cleanup: @escaping @Sendable (Date, Int) async throws -> Int,
    logger: Logger,
    telemetry: OperationsTelemetryBuffer? = nil,
    catchUpEnabled: Bool = false,
    now: @escaping @Sendable () -> Date = Date.init,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.catchUpEnabled = catchUpEnabled
    self.cleanup = cleanup
    self.logger = logger
    self.telemetry = telemetry
    self.now = now
    self.sleep = sleep
  }

  func runForever() async {
    var consecutiveFailures = 0
    while !Task.isCancelled {
      let started = ContinuousClock.now
      let delay: Duration
      do {
        let round = try await runRound()
        consecutiveFailures = 0
        delay = round.drained || !catchUpEnabled ? .seconds(3_600) : .seconds(1)
        let completedAt = now()
        let duration = started.duration(to: .now)
        let milliseconds = Double(duration.components.seconds) * 1_000
          + Double(duration.components.attoseconds) / 1_000_000_000_000_000
        // Expired-row counts continue to come from the bounded database-cost sampler.
        // This progress signal means more cleanup may be available, not retained history.
        for (name, value) in [
          ("deleted_rows", Double(round.deleted)),
          ("calls", Double(round.calls)),
          ("duration_ms", milliseconds),
          ("last_success_timestamp", completedAt.timeIntervalSince1970),
          ("backlog_pending", round.drained ? 0.0 : 1.0),
        ] {
          await emit(name: name, value: value, at: completedAt)
        }
        logger.info("Operations retention cleanup round", metadata: [
          "deleted_rows": .stringConvertible(round.deleted),
          "calls": .stringConvertible(round.calls),
          "backlog_pending": .stringConvertible(!round.drained),
          "duration_ms": .stringConvertible(milliseconds),
        ])
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled else { return }
        consecutiveFailures += 1
        delay = catchUpEnabled
          ? Self.failureDelay(consecutiveFailures: consecutiveFailures) : .seconds(3_600)
        await emit(name: "failures", value: 1, at: now())
        logger.warning("Operations retention cleanup failed", metadata: [
          "error_type": .string(OperationsRedactor.errorCategory(error)),
          "consecutive_failures": .stringConvertible(consecutiveFailures),
        ])
      }
      do { try await sleep(delay) } catch { return }
    }
  }

  func runRound() async throws -> (deleted: Int, calls: Int, drained: Bool) {
    var total = 0
    for call in 1...10 {
      try Task.checkCancellation()
      let deleted = try await cleanup(now(), 1_000)
      total += deleted
      if deleted == 0 { return (total, call, true) }
    }
    return (total, 10, false)
  }

  static func failureDelay(consecutiveFailures: Int) -> Duration {
    .seconds([5, 10, 20, 40, 60][max(0, min(consecutiveFailures - 1, 4))])
  }

  private func emit(name: String, value: Double, at: Date) async {
    await telemetry?.enqueue(.metric(OperationsMetricSample(
      name: "operations.retention.\(name)", value: value,
      dimensions: ["service": "operations"], recordedAt: at)))
  }
}
