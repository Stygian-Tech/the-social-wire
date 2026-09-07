import Foundation
import Logging

struct WireTalkedAccountProfileEnricher: Sendable {
  let store: any WireTalkedAccountProfileStoring
  let client: any WireTalkedAccountProfileFetching
  let logger: Logger
  let batchSize: Int
  let maximumConcurrentFetches: Int

  func runBatch(asOf: Date) async throws -> Int {
    try Task.checkCancellation()
    let dids = try await store.claimDue(limit: batchSize, asOf: asOf)
    try Task.checkCancellation()
    var iterator = dids.makeIterator()
    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<min(maximumConcurrentFetches, dids.count) {
        guard let did = iterator.next() else { break }
        group.addTask { try await refresh(did: did, asOf: asOf) }
      }
      while try await group.next() != nil {
        try Task.checkCancellation()
        guard let did = iterator.next() else { continue }
        group.addTask { try await refresh(did: did, asOf: asOf) }
      }
    }
    return dids.count
  }

  private func refresh(did: String, asOf: Date) async throws {
    do {
      try Task.checkCancellation()
      let profile = try await client.fetch(did: did)
      try Task.checkCancellation()
      try await store.store(profile, asOf: asOf)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      try Task.checkCancellation()
      try? await store.markFailure(did: did, asOf: asOf)
      try Task.checkCancellation()
      logger.debug("The Wire public profile refresh failed")
    }
  }
}
