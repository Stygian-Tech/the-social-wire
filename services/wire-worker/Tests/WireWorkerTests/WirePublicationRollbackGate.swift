import Foundation

@testable import WireWorkerCore

/// Suspends post-transaction invalidation before the separately fenced terminal update.
actor WirePublicationRollbackGate: WirePublicationResolving {
  nonisolated let rolledBack: AsyncStream<Void>
  private let signal: AsyncStream<Void>.Continuation
  private var waiter: CheckedContinuation<Void, Never>?
  private var released = false
  private var invalidations = 0

  init() { (rolledBack, signal) = AsyncStream.makeStream(of: Void.self) }

  func invalidate(publicationURI: String) async {
    invalidations += 1
    guard invalidations == 2, !released else { return }
    await withCheckedContinuation { continuation in
      waiter = continuation
      signal.yield(())
      signal.finish()
    }
  }

  func release() {
    released = true
    waiter?.resume()
    waiter = nil
  }

  func observe(_ metadata: WirePublicationMetadata, asOf: Date) async throws {}
  func resolve(publicationURI: String, asOf: Date) async throws -> WirePublicationMetadata? { nil }
  func remove(publicationURI: String, observedAt: Date) async throws {}
}
