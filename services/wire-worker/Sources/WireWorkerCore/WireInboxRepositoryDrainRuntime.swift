import Foundation
import Logging

enum WireInboxRepositoryDrainRuntime {
  private enum Completion: Sendable { case turnFinished, admissionReady }
  struct Configuration: Sendable {
    var maximumConcurrentEvents = 16
    var maximumEventsPerTurn = 16
    var maximumTurnSeconds: TimeInterval = 1
    var idleMilliseconds = 250
    var initialErrorBackoffMilliseconds = 1_000
    var maximumErrorBackoffMilliseconds = 30_000
  }

  static func run(
    processor: any WireInboxRepositoryProcessing,
    state: WireWorkerHealthState,
    logger: Logger,
    configuration: Configuration,
    telemetry: WireInboxDrainTelemetryState? = nil,
    clock: any WireInboxDrainClock = SystemWireInboxDrainClock(),
    sleeper: any WireInboxDrainSleeping = SystemWireInboxDrainSleeper()
  ) async throws {
    let concurrency = min(64, max(1, configuration.maximumConcurrentEvents))
    var cursor: WireInboxRepository?
    var backoff = max(1, configuration.initialErrorBackoffMilliseconds)
    try await withThrowingTaskGroup(of: Completion.self) { tasks in
      var active = 0
      var admissionTimerPending = false
      while !Task.isCancelled {
        if active < concurrency {
          let startedAt = await clock.now()
          await state.recordDrainStarted(at: startedAt)
          do {
            let batch = try await processor.claimWork(
              asOf: startedAt, limit: concurrency - active, afterRepository: cursor)
            await state.recordDrainSuccess(at: await clock.now())
            if let telemetry {
              await telemetry.recordAppliedEvents(batch.appliedPassiveEventCount)
            }
            cursor = batch.nextRepositoryCursor
            backoff = max(1, configuration.initialErrorBackoffMilliseconds)
            for event in batch.events {
              active += 1
              tasks.addTask {
                try await runTurn(
                  first: event, processor: processor, state: state, logger: logger,
                  configuration: configuration, telemetry: telemetry, clock: clock)
                return .turnFinished
              }
            }
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            await state.recordDrainFailure(error)
            logger.error(
              "The Wire repository admission failed",
              metadata: [
                "retry_milliseconds": .string(String(backoff))
              ])
            try await sleeper.sleep(milliseconds: backoff)
            backoff = min(backoff * 2, max(1, configuration.maximumErrorBackoffMilliseconds))
          }
        }
        if active < concurrency, !admissionTimerPending {
          admissionTimerPending = true
          tasks.addTask {
            try await sleeper.sleep(milliseconds: max(1, configuration.idleMilliseconds))
            return .admissionReady
          }
        }
        // A single bounded timer keeps unused capacity available to repositories
        // arriving while every current turn is waiting on a slow dependency.
        switch try await tasks.next() {
        case .turnFinished: active -= 1
        case .admissionReady: admissionTimerPending = false
        case nil: break
        }
      }
      tasks.cancelAll()
      throw CancellationError()
    }
  }

  private static func runTurn(
    first: WireInboxEvent,
    processor: any WireInboxRepositoryProcessing,
    state: WireWorkerHealthState,
    logger: Logger,
    configuration: Configuration,
    telemetry: WireInboxDrainTelemetryState?,
    clock: any WireInboxDrainClock
  ) async throws {
    let operationID = UUID().uuidString
    let startedAt = await clock.now()
    let maximumEvents = max(1, min(configuration.maximumEventsPerTurn, 64))
    var event = first
    do {
      for index in 0..<maximumEvents {
        try Task.checkCancellation()
        let eventStartedAt = await clock.now()
        await state.recordDrainEventStarted(id: operationID, at: eventStartedAt)
        let outcome = try await processor.applyClaimed(event, asOf: eventStartedAt)
        await state.recordDrainEventFinished(id: operationID, at: await clock.now())
        if outcome == .applied, let telemetry {
          await telemetry.recordAppliedEvents(1)
        }
        if outcome == .deferred, let telemetry {
          await telemetry.recordDeferredEvents(1)
        }
        try Task.checkCancellation()
        guard outcome.permitsContinuation, !event.isPassiveDelete,
          index + 1 < maximumEvents,
          (await clock.now()).timeIntervalSince(startedAt)
            < max(0, configuration.maximumTurnSeconds)
        else { return }
        // Claim only the next unfinished head, with a fresh single-event lease.
        // A retry, another owner's live lease, or concurrent claim stops this turn.
        await state.recordDrainEventStarted(id: operationID, at: await clock.now())
        let next = try await processor.claimNext(in: event.repository, asOf: await clock.now())
        await state.recordDrainEventFinished(id: operationID, at: await clock.now())
        guard let next else { return }
        event = next
      }
    } catch is CancellationError {
      await state.recordDrainEventStopped(id: operationID)
      throw CancellationError()
    } catch {
      await state.recordDrainEventFailed(id: operationID, error: error)
      // Other repositories retain their current turns. Any unfinished event is
      // still protected by its existing lease and can be recovered after expiry.
      logger.error("The Wire repository turn failed")
    }
  }
}
