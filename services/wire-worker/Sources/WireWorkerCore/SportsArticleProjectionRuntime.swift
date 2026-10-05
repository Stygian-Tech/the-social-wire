import Foundation
import Logging

/// Sports failures never stop or delay the separate Wire inbox drain task.
enum SportsArticleProjectionRuntime {
  static func run(projector: PostgresSportsArticleProjector, logger: Logger) async throws {
    try await runScheduled(operation: { _ = try await projector.project(asOf: Date()) }, logger: logger)
  }

  static func runScheduled(operation: @Sendable () async throws -> Void, logger: Logger,
    sleep: @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(15)) },
    iterationLimit: Int? = nil) async throws {
    var iterations = 0
    while !Task.isCancelled && iterationLimit.map({ iterations < $0 }) ?? true {
      do { try await operation() }
      catch is CancellationError { throw CancellationError() }
      catch { logger.warning("Sports article projection failed; retaining prior analysis") }
      iterations += 1
      try await sleep()
    }
  }
}
