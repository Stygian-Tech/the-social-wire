import Foundation

@testable import WireWorkerCore

actor RepositoryDrainFixture: WireInboxRepositoryProcessing {
  private var queues: [String: [WireInboxEvent]] = [:]
  private let blockedRepository: String?
  private let outcomes: [String: WireInboxEventOutcome]
  private let passiveDeletes: Bool
  private let blocked = AsyncStream<Void>.makeStream()
  private let changes = AsyncStream<Void>.makeStream()
  private var applying: Set<String> = []
  private(set) var leased: Set<String> = []
  private(set) var completed: [WireInboxEvent] = []
  private(set) var started: Set<String> = []
  private(set) var admissions: [String] = []
  private(set) var admissionCount = 0
  private(set) var nextClaims: [String: Int] = [:]
  private(set) var maximumLeased = 0
  private(set) var maximumApplying = 0
  private(set) var claimedConcurrentlyInSameRepository = false

  init(
    queues: [String: Int], blockedRepository: String? = nil,
    outcomes: [String: WireInboxEventOutcome] = [:], passiveDeletes: Bool = false
  ) {
    self.blockedRepository = blockedRepository
    self.outcomes = outcomes
    self.passiveDeletes = passiveDeletes
    self.queues = queues.mapValues { _ in [] }
    for (repository, count) in queues {
      self.queues[repository] = (1...count).map {
        Self.event(repository: repository, sequence: $0, passiveDelete: passiveDeletes)
      }
    }
  }

  func add(repository: String, count: Int) {
    queues[repository] = (1...count).map {
      Self.event(repository: repository, sequence: $0, passiveDelete: passiveDeletes)
    }
    changes.continuation.yield()
  }

  func claimWork(asOf: Date, limit: Int, afterRepository: WireInboxRepository?)
    -> WireInboxWorkBatch
  {
    admissionCount += 1
    let ready = queues.keys.sorted().filter {
      !leased.contains($0) && !(queues[$0]?.isEmpty ?? true)
    }
    let later = ready.filter { $0 > (afterRepository?.repoDID ?? "") }
    let selected = Array((later.isEmpty ? ready : later).prefix(limit))
    let events = selected.compactMap { claim($0) }
    admissions.append(contentsOf: selected)
    changes.continuation.yield()
    return .init(
      events: events, appliedPassiveEventCount: 0,
      nextRepositoryCursor: events.last?.repository ?? afterRepository)
  }

  func claimNext(in repository: WireInboxRepository, asOf: Date) -> WireInboxEvent? {
    nextClaims[repository.repoDID, default: 0] += 1
    return claim(repository.repoDID)
  }

  private func claim(_ repository: String) -> WireInboxEvent? {
    guard !leased.contains(repository), let first = queues[repository]?.first else { return nil }
    leased.insert(repository)
    maximumLeased = max(maximumLeased, leased.count)
    return first
  }

  func applyClaimed(_ event: WireInboxEvent, asOf: Date) async throws -> WireInboxEventOutcome {
    if !applying.insert(event.repoDID).inserted { claimedConcurrentlyInSameRepository = true }
    maximumApplying = max(maximumApplying, applying.count)
    started.insert(event.repoDID)
    changes.continuation.yield()
    if event.repoDID == blockedRepository {
      var iterator = blocked.stream.makeAsyncIterator()
      _ = await iterator.next()
    } else {
      await Task.yield()
    }
    try Task.checkCancellation()
    applying.remove(event.repoDID)
    let outcome = event.sequence == 1 ? outcomes[event.repoDID] ?? .applied : .applied
    if outcome.permitsContinuation {
      queues[event.repoDID]?.removeFirst()
      leased.remove(event.repoDID)
    }
    completed.append(event)
    changes.continuation.yield()
    return outcome
  }

  func waitUntil(_ condition: @Sendable (isolated RepositoryDrainFixture) -> Bool) async throws {
    var iterator = changes.stream.makeAsyncIterator()
    while !condition(self) {
      try Task.checkCancellation()
      guard await iterator.next() != nil else { throw CancellationError() }
    }
  }

  private static func event(repository: String, sequence: Int, passiveDelete: Bool)
    -> WireInboxEvent
  {
    .init(
      environment: "test", sourceGeneration: "g1", sequence: Int64(sequence),
      sourceHost: "test", cursorKind: "seq", eventKind: "commit", repoDID: repository,
      collection: passiveDelete ? "app.bsky.feed.like" : "site.standard.document",
      operation: passiveDelete ? "delete" : "create", recordKey: String(sequence),
      payloadJSON: "{}", eventTime: Date(), leaseToken: "\(repository)-\(sequence)", attemptCount: 1
    )
  }
}
