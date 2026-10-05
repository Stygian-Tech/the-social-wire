import Foundation
import Logging

/// Finance failures never stop or delay the separate Wire inbox drain task.
enum FinanceArticleProjectionRuntime {
  static func run(projector: PostgresFinanceArticleProjector, logger: Logger) async throws {
    try await runScheduled(operation: { _ = try await projector.project(asOf: Date()) }, logger: logger)
  }

  static func runScheduled(operation: @Sendable () async throws -> Void, logger: Logger,
    sleep: @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(15)) },
    iterationLimit: Int? = nil) async throws {
    var iterations = 0
    while !Task.isCancelled && iterationLimit.map({ iterations < $0 }) ?? true {
      do { try await operation() }
      catch is CancellationError { throw CancellationError() }
      catch { logger.warning("Finance article projection failed; retaining prior analysis") }
      iterations += 1
      try await sleep()
    }
  }
}
