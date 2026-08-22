import Foundation
import Logging

struct WireTalkedAccountProfileEnricher: Sendable {
  let store: any WireTalkedAccountProfileStoring
  let client: any WireTalkedAccountProfileFetching
  let logger: Logger
  let batchSize: Int
  let maximumConcurrentFetches: Int

  func runBatch(asOf: Date) async throws -> Int {
    let dids = try await store.claimDue(limit: batchSize, asOf: asOf)
    var iterator = dids.makeIterator()
    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<min(maximumConcurrentFetches, dids.count) {
        guard let did = iterator.next() else { break }
        group.addTask { await refresh(did: did, asOf: asOf) }
      }
      while try await group.next() != nil {
        guard let did = iterator.next() else { continue }
        group.addTask { await refresh(did: did, asOf: asOf) }
      }
    }
    return dids.count
  }

  private func refresh(did: String, asOf: Date) async {
    do {
      try await store.store(try await client.fetch(did: did), asOf: asOf)
    } catch {
      try? await store.markFailure(did: did, asOf: asOf)
      logger.debug("The Wire public profile refresh failed")
    }
  }
}
