import Logging

/// Close outbound transports as cancellation begins, before joining children that may
/// be waiting on those transports. The shutdown task is owned and joined exactly once.
enum WireWorkerLifetime {
  static func run(
    logger: Logger,
    shutdown: @escaping @Sendable () async throws -> Void,
    configure: @Sendable (inout ThrowingTaskGroup<Void, any Error>) -> Void
  ) async throws {
    let (signal, continuation) = AsyncStream<Void>.makeStream()
    let shutdownTask = Task {
      for await _ in signal {}
      logger.info("The Wire outbound transport shutdown started")
      do {
        try await shutdown()
        logger.info("The Wire outbound transport shutdown completed")
      } catch {
        logger.warning("The Wire outbound transport shutdown failed")
      }
    }
    var failure: (any Error)?
    do {
      try await withTaskCancellationHandler {
        try await withThrowingTaskGroup(of: Void.self) { group in
          defer {
            continuation.finish()
            group.cancelAll()
          }
          configure(&group)
          try await group.next()
        }
      } onCancel: {
        continuation.finish()
        logger.info("The Wire runtime cancellation requested")
      }
    } catch {
      failure = error
    }
    continuation.finish()
    await shutdownTask.value
    logger.info("The Wire runtime children stopped")
    if let failure { throw failure }
  }
}
