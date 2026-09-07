import Foundation
import Logging

struct WireLinkMetadataEnricher: Sendable {
  let store: any WireLinkMetadataStoring
  let client: any WireLinkMetadataFetching
  let logger: Logger
  let batchSize: Int
  let maximumConcurrentFetches: Int

  func runBatch(asOf: Date) async throws -> Int {
    try Task.checkCancellation()
    let targets = try await store.claimDue(limit: batchSize, asOf: asOf)
    try Task.checkCancellation()
    guard !targets.isEmpty else { return 0 }
    var iterator = targets.makeIterator()
    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<min(maximumConcurrentFetches, targets.count) {
        guard let target = iterator.next() else { break }
        group.addTask { try await enrich(target, asOf: asOf) }
      }
      while try await group.next() != nil {
        try Task.checkCancellation()
        guard let target = iterator.next() else { continue }
        group.addTask { try await enrich(target, asOf: asOf) }
      }
    }
    return targets.count
  }

  func healthSnapshot(asOf: Date) async throws -> WireEnrichmentHealthSnapshot? {
    try await store.healthSnapshot(asOf: asOf)
  }

  private func enrich(_ target: WireLinkMetadataTarget, asOf: Date) async throws {
    do {
      try Task.checkCancellation()
      let result = try await client.fetch(target)
      try Task.checkCancellation()
      switch result {
      case .notModified(let etag, let lastModified):
        try await store.markNotModified(
          canonicalKey: target.canonicalKey,
          etag: etag,
          lastModified: lastModified,
          asOf: asOf
        )
      case .metadata(let metadata):
        try await store.store(canonicalKey: target.canonicalKey, metadata: metadata, asOf: asOf)
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      try Task.checkCancellation()
      let negative = Self.isNegative(error)
      try? await store.markFailure(canonicalKey: target.canonicalKey, negative: negative, asOf: asOf)
      try Task.checkCancellation()
      logger.debug(
        "The Wire metadata enrichment failed",
        metadata: ["category": .string(negative ? "negative" : "retry")]
      )
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
