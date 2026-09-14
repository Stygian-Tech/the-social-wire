import Foundation
import Logging
import OperationsCore

enum LegacyJetstreamAuthorityLease {
  static let leaseName = "charybdis-v1-projection-authority"
  static let sourceGeneration = "jetstream-v1"

  static func runForever(
    store: (any OperationsStore)?,
    ownerID: String,
    leaseSeconds: TimeInterval = 60,
    minimumLeaseSeconds: TimeInterval = 15,
    contentionSleepSeconds: TimeInterval = 1,
    logger: Logger,
    now: @escaping @Sendable () -> Date = Date.init,
    authority: @escaping @Sendable (IngestionLeaderLease?) async -> Void
  ) async {
    guard let store else {
      await authority(nil)
      return
    }
    let duration = max(minimumLeaseSeconds, leaseSeconds)
    while !Task.isCancelled {
      do {
        let acquiredAt = now()
        guard let lease = try await store.acquireIngestionLeaderLease(
          name: leaseName,
          sourceGeneration: sourceGeneration,
          ownerID: ownerID,
          leaseUntil: acquiredAt.addingTimeInterval(duration),
          at: acquiredAt
        ) else {
          try await Task.sleep(for: .seconds(contentionSleepSeconds))
          continue
        }
        logger.info(
          "Acquired legacy Jetstream projection authority",
          metadata: ["fencing_token": .stringConvertible(lease.fencingToken)]
        )
        do {
          try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await authority(lease) }
            group.addTask {
              var current = lease
              while !Task.isCancelled {
                try await Task.sleep(for: .seconds(duration / 3))
                try Task.checkCancellation()
                let renewedAt = now()
                current = try await store.renewIngestionLeaderLease(
                  name: leaseName,
                  ownerID: ownerID,
                  fencingToken: current.fencingToken,
                  leaseUntil: renewedAt.addingTimeInterval(duration),
                  at: renewedAt
                )
              }
            }
            _ = try await group.next()
            group.cancelAll()
          }
        } catch is CancellationError {
          try? await store.releaseIngestionLeaderLease(
            name: leaseName, ownerID: ownerID, fencingToken: lease.fencingToken, at: now())
          return
        } catch {
          logger.warning(
            "Lost legacy Jetstream projection authority",
            metadata: ["fencing_token": .stringConvertible(lease.fencingToken)]
          )
        }
        try? await store.releaseIngestionLeaderLease(
          name: leaseName, ownerID: ownerID, fencingToken: lease.fencingToken, at: now())
      } catch is CancellationError {
        return
      } catch {
        // Hosted workers fail closed until the durable lease store is reachable.
        logger.warning("Legacy Jetstream projection authority lease unavailable")
        try? await Task.sleep(for: .seconds(contentionSleepSeconds))
      }
    }
  }
}
