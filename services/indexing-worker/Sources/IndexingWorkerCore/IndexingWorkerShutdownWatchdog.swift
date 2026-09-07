import Logging

enum IndexingWorkerShutdownWatchdog {
  /// A cancelled lane must fully stop before reacquisition. If it cannot, terminate
  /// this process so Railway can replace it; never detach the old lane and overlap it.
  static func run(
    state: IndexingWorkerLaneState,
    logger: Logger,
    terminate: @escaping @Sendable () -> Void
  ) async throws {
    while !Task.isCancelled {
      if let lane = await state.unresponsiveLane() {
        logger.critical("Cancelled indexing lane did not stop within 30 seconds; exiting for recovery",
          metadata: ["lane": .string(lane.rawValue)])
        terminate()
        return
      }
      try await Task.sleep(for: .seconds(5))
    }
  }
}
