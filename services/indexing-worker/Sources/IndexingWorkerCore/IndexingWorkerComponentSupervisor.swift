import Logging

enum IndexingWorkerComponentSupervisor {
  static func run(
    lane: IndexingWorkerLane,
    state: IndexingWorkerLaneState,
    logger: Logger,
    operation: @Sendable @escaping () async throws -> Void
  ) async throws {
    var backoffNanoseconds: UInt64 = 250_000_000
    while !Task.isCancelled {
      await state.set(.starting, for: lane)
      do {
        await state.set(.running, for: lane)
        try await operation()
        guard !Task.isCancelled else { return }
        throw IndexingWorkerSupervisorError.unexpectedExit(lane)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        await state.set(.restarting, for: lane)
        logger.error(
          "Indexing component stopped; restarting independently",
          metadata: ["lane": .string(lane.rawValue), "error": .string(String(describing: error))]
        )
        try await Task.sleep(nanoseconds: backoffNanoseconds)
        backoffNanoseconds = min(backoffNanoseconds * 2, 10_000_000_000)
      }
    }
  }
}

enum IndexingWorkerSupervisorError: Error, Equatable {
  case unexpectedExit(IndexingWorkerLane)
}
