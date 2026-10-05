import Foundation
import Logging

/// Fenced Coordinator task: provider latency never delays Wire or Sports generation.
enum SportsProviderRuntime {
  static func run(refresh: PostgresSportsProviderRefresh, logger: Logger) async throws {
    while !Task.isCancelled {
      do { try await refresh.run(asOf: Date()) }
      catch is CancellationError { throw CancellationError() }
      catch { logger.warning("Sports provider refresh failed; retaining prior reference and event snapshots") }
      try await Task.sleep(for: .seconds(15))
    }
  }
}
