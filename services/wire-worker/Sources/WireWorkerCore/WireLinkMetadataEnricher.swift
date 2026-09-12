import Foundation
import Logging

struct WireLinkMetadataEnricher: Sendable {
  let store: any WireLinkMetadataStoring
  let client: any WireLinkMetadataFetching
  let logger: Logger
  let batchSize: Int
  let maximumConcurrentFetches: Int

  var now: @Sendable () -> Date = { Date() }
  var fetchTimeout: Duration = .seconds(240)

  func runBatch(asOf: Date) async throws -> Int {
    try Task.checkCancellation()
    let targets = try await store.claimDue(limit: batchSize, asOf: asOf)
    try Task.checkCancellation()
    guard !targets.isEmpty else { return 0 }
    var iterator = targets.makeIterator()
    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<min(max(1, maximumConcurrentFetches), targets.count) {
        guard let target = iterator.next() else { break }
        group.addTask { try await enrich(target) }
      }
      while try await group.next() != nil {
        try Task.checkCancellation()
        guard let target = iterator.next() else { continue }
        group.addTask { try await enrich(target) }
      }
    }
    return targets.count
  }

  func healthSnapshot(asOf: Date) async throws -> WireEnrichmentHealthSnapshot? {
    try await store.healthSnapshot(asOf: asOf)
  }

  private func enrich(_ target: WireLinkMetadataTarget) async throws {
    var target = target
    try Task.checkCancellation()
    // Preserve batch selection and its priority/general split. A queued target
    // may have been reclaimed while waiting for a slot: renew by the original
    // lease token before starting IO, and abandon it if ownership has changed.
    if let expiry = target.leaseExpiresAt,
      Duration.seconds(expiry.timeIntervalSince(now()) - 5) < fetchTimeout
    {
      guard let renewed = try await store.renewClaim(target, asOf: now()) else { return }
      target = renewed
    }
    try Task.checkCancellation()
    let timeout: Duration
    if let expiry = target.leaseExpiresAt {
      let remaining = expiry.timeIntervalSince(now()) - 5
      guard remaining > 0 else { return }
      timeout = min(fetchTimeout, .seconds(remaining))
    } else {
      timeout = fetchTimeout
    }
    do {
      let result = try await fetch(target, timeout: timeout)
      try Task.checkCancellation()
      let completedAt = now()
      switch result {
      case .notModified(let etag, let lastModified):
        try await store.markNotModified(
          canonicalKey: target.canonicalKey,
          etag: etag,
          lastModified: lastModified,
          asOf: completedAt, leaseExpiresAt: target.leaseExpiresAt
        )
      case .metadata(let metadata):
        try await store.store(
          canonicalKey: target.canonicalKey, metadata: metadata,
          asOf: completedAt, leaseExpiresAt: target.leaseExpiresAt)
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      try Task.checkCancellation()
      let negative = Self.isNegative(error)
      try? await store.markFailure(
        canonicalKey: target.canonicalKey, negative: negative,
        asOf: now(), leaseExpiresAt: target.leaseExpiresAt)
      try Task.checkCancellation()
      logger.debug(
        "The Wire metadata enrichment failed",
        metadata: ["category": .string(negative ? "negative" : "retry")]
      )
    }
  }

  private func fetch(
    _ target: WireLinkMetadataTarget, timeout: Duration
  ) async throws -> WireLinkMetadataFetchResult {
    // Bound the entire redirect/DNS/body operation below the five-minute lease.
    // Structured cancellation waits for transport teardown before this slot is reused.
    try await withThrowingTaskGroup(of: WireLinkMetadataFetchResult.self) { group in
      group.addTask { try await client.fetch(target) }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw WireLinkMetadataFetchTimeout()
      }
      defer { group.cancelAll() }
      return try await group.next()!
    }
  }

  private static func isNegative(_ error: Error) -> Bool {
    guard let error = error as? WireLinkMetadataQueryError else { return false }
    switch error {
    case .unsafeEndpoint, .invalidResponse, .unsupportedContentType, .responseTooLarge,
      .tooManyRedirects:
      return true
    case .transientStatus:
      return false
    }
  }
}
