import Foundation

/// A recovery cursor belongs to one fenced event, never just a DID or a process.
public struct PDSRepositoryRecoveryContext: Sendable {
  public let environment: String
  public let sourceGeneration: String
  public let sequence: Int64
  public let repoDid: String
  public let requestId: String?
  public let workerId: String
  public let leaseToken: String

  var key: String { requestId.map { "request:\($0)" } ?? "sync:\(sequence)" }
}

struct PDSRepositoryRecoveryState: Codable, Sendable {
  var snapshotId = UUID().uuidString
  var pruningComplete = false
  var pruneCreatedAt: Date?
  var pruneURI: String?
  var startedAt = Date()
  var pdsBase: String?
  var collections: [String: Collection] = [:]
  var completed = false

  struct Collection: Codable, Sendable {
    var cursor: String?
    var seenCursors: Set<String> = []
    var observedCount = 0
    var indexedCount = 0
    var complete = false
  }
}

protocol PDSRepositoryRecoveryStore: Sendable {
  func loadRepositoryRecovery(_ context: PDSRepositoryRecoveryContext) async throws
    -> PDSRepositoryRecoveryState
  /// The owner lease is checked and locked in the same transaction as cursor/URI publication.
  @discardableResult
  func saveRepositoryRecovery(
    _ context: PDSRepositoryRecoveryContext, state: PDSRepositoryRecoveryState,
    observedURIs: [String], finish: Bool
  ) async throws -> PDSRepositoryRecoveryState
  /// A bounded successful slice yields without consuming the failure retry budget.
  func yieldRepositoryRecovery(_ context: PDSRepositoryRecoveryContext) async throws
}

enum PDSRepositoryRecoveryError: Error {
  case yielded
  case pageLimitExceeded
  case unavailable
}

actor PDSRepositoryRecovery {
  let context: PDSRepositoryRecoveryContext
  let store: any PDSRepositoryRecoveryStore
  private(set) var state: PDSRepositoryRecoveryState

  init(context: PDSRepositoryRecoveryContext, store: any PDSRepositoryRecoveryStore,
       state: PDSRepositoryRecoveryState) {
    self.context = context
    self.store = store
    self.state = state
  }

  func validateEndpoint(_ pds: String) async throws {
    if let previous = state.pdsBase, previous != pds, !state.completed {
      // Cursor semantics are local to a PDS. Start a new snapshot namespace without deleting
      // content or discarding the original cutoff that protects concurrent live commits.
      var fresh = PDSRepositoryRecoveryState()
      fresh.startedAt = state.startedAt
      fresh.pdsBase = pds
      state = try await store.saveRepositoryRecovery(context, state: fresh, observedURIs: [], finish: false)
    } else if state.pdsBase == nil {
      var next = state
      next.pdsBase = pds
      state = try await store.saveRepositoryRecovery(context, state: next, observedURIs: [], finish: false)
    }
  }

  func collection(_ name: String) -> PDSRepositoryRecoveryState.Collection {
    state.collections[name] ?? .init()
  }

  func checkpoint(collection: String, value: PDSRepositoryRecoveryState.Collection,
                  observedURIs: [String]) async throws {
    // Even a hostile endpoint with endlessly changing cursors cannot grow checkpoint state forever.
    guard value.seenCursors.count <= 10_000 else {
      throw PDSRepositoryRecoveryError.pageLimitExceeded
    }
    var next = state
    next.collections[collection] = value
    state = try await store.saveRepositoryRecovery(context, state: next, observedURIs: observedURIs, finish: false)
  }

  func finish() async throws {
    var next = state
    next.completed = true
    state = try await store.saveRepositoryRecovery(context, state: next, observedURIs: [], finish: true)
    if !state.completed { throw PDSRepositoryRecoveryError.yielded }
  }
}
