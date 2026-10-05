import Foundation
import Logging

enum WireWorkerRuntime {
  static func runForever(
    cycle: WireWorkerCycle,
    state: WireWorkerHealthState,
    scheduler: WireRankingScheduler = WireRankingScheduler(),
    logger: Logger,
    financeMaterializer: PostgresFinanceMaterializer? = nil,
    sportsMaterializer: PostgresSportsMaterializer? = nil
  ) async throws {
    try await runScheduled(
      intervalSeconds: cycle.config.intervalSeconds, scheduler: scheduler,
      operation: {
        let cycleStart = ContinuousClock.now
        let startedAt = Date()
        let outcome = try await runGenerationWithSportsCatalog(
          refreshCatalog: { try await sportsMaterializer?.refreshReviewedCatalog(asOf: startedAt) },
          generateWire: { try await cycle.run(asOf: startedAt) },
          onCatalogFailure: { _ in logger.warning("Sports catalog refresh failed; retaining prior catalog") })
        try Task.checkCancellation()
        let elapsed = cycleStart.duration(to: .now)
        let durationMilliseconds = Double(elapsed.components.seconds) * 1_000
          + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
        await state.recordGenerationSuccess(at: startedAt, durationMilliseconds: durationMilliseconds)
        switch outcome {
        case .off:
          logger.info("The Wire is remotely off")
        case .generated(let id, let itemCount, let activated):
          do {
            try await cycle.store.recordCycleDuration(
              milliseconds: durationMilliseconds, generationID: id)
          } catch {
            logger.debug("The Wire cycle duration export unavailable")
          }
          logger.info(
            "The Wire generation committed",
            metadata: [
              "generation_id": .string(id.uuidString.lowercased()),
              "item_count": .string(String(itemCount)),
              "cycle_duration_ms": .stringConvertible(durationMilliseconds),
              "activated": .string(String(activated)),
            ]
          )
          if let financeMaterializer {
            do { try await financeMaterializer.run(asOf: startedAt) }
            catch {
              logger.warning("Finance materialization failed after successful Wire cycle")
            }
          }
        }
        if let sportsMaterializer {
          do { try await sportsMaterializer.run(asOf: startedAt) }
          catch { logger.warning("Sports materialization failed; retaining prior generation") }
        }
      }, onFailure: { error in
        await state.recordGenerationFailure(error)
        logger.error("The Wire generation cycle failed", metadata: ["error": .string(String(reflecting: error))])
      })
  }

  /// Sports identities refresh inside the reserved/fenced Coordinator lifecycle,
  /// before Wire ranking can fail. Optional catalog failure cannot revoke Wire work.
  static func runGenerationWithSportsCatalog<Outcome: Sendable>(
    refreshCatalog: @Sendable () async throws -> Void,
    generateWire: @Sendable () async throws -> Outcome,
    onCatalogFailure: @Sendable (any Error) async -> Void
  ) async throws -> Outcome {
    try Task.checkCancellation()
    do { try await refreshCatalog() }
    catch {
      if error is CancellationError || Task.isCancelled { throw CancellationError() }
      await onCatalogFailure(error)
    }
    try Task.checkCancellation()
    return try await generateWire()
  }

  static func runScheduled(
    intervalSeconds: Int,
    scheduler: WireRankingScheduler,
    sleeper: any WireInboxDrainSleeping = SystemWireInboxDrainSleeper(),
    monotonicNow: @Sendable () async -> ContinuousClock.Instant = { .now },
    iterationLimit: Int? = nil,
    operation: @Sendable () async throws -> Void,
    onFailure: @Sendable (any Error) async -> Void = { _ in }
  ) async throws {
    var iterations = 0
    while !Task.isCancelled, iterationLimit.map({ iterations < $0 }) ?? true {
      let reservation = await scheduler.reserve(at: monotonicNow())
      guard case .run(let token) = reservation else {
        if case .wait(let milliseconds) = reservation {
          try await sleeper.sleep(milliseconds: milliseconds)
        }
        continue
      }
      do {
        try Task.checkCancellation()
        // The operation returns only after every language/plan and its awaited
        // cleanup complete. A single published generation is not cycle success.
        try await operation()
        try Task.checkCancellation()
        await scheduler.succeeded(token, at: monotonicNow(), intervalSeconds: intervalSeconds)
      } catch {
        let canceled = error is CancellationError || Task.isCancelled
        if !canceled { await onFailure(error) }
        await scheduler.failed(token, at: monotonicNow())
        if canceled || Task.isCancelled { throw CancellationError() }
      }
      iterations += 1
    }
  }
}
