import Foundation
import Logging

enum WirePublicationSignalRecoveryRuntime {
  static func run(recovery: PostgresWirePublicationSignalRecovery, logger: Logger) async throws {
    while !Task.isCancelled {
      do {
        let count = try await recovery.runBatch(asOf: Date())
        if count == 0 { try await Task.sleep(for: .seconds(5)) }
        else { await Task.yield() }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // Database errors may include source identities. Keep runtime telemetry
        // categorical; the transaction leaves its cursor available for retry.
        logger.warning("The Wire publication recovery batch failed; retrying")
        try await Task.sleep(for: .seconds(5))
      }
    }
  }
}
