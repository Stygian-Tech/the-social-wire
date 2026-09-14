import Foundation
import Logging
import PostgresNIO

/// Bounded Coordinator child; the existing materializer lifetime cancels it on
/// lease loss. Durable per-record tokens fence every post-network write as well.
actor WireRecommendationHydrator {
  private let store: PostgresWireDependencyRecoveryStore
  private let verifier: any WirePublicRecordVerifying
  private let processor: PostgresWireInboxProcessor
  private let logger: Logger
  private var seedCursor: PostgresWireDependencyRecoveryStore.SeedCursor?
  private var subjects: [String: Task<Int, Error>] = [:]

  init(pool: PostgresClient, logger: Logger, environment: String,
    verifier: any WirePublicRecordVerifying, processor: PostgresWireInboxProcessor)
  {
    self.store = .init(pool: pool, logger: logger, environment: environment)
    self.verifier = verifier
    self.processor = processor
    self.logger = logger
  }

  func hydrate(asOf: Date, limit: Int = 16) async throws -> WireRecommendationHydrationCounts {
    try Task.checkCancellation()
    // Cancellation leaves original envelopes and durable leases intact. A slow
    // repository cannot consume an unbounded Coordinator recovery cycle.
    return try await withThrowingTaskGroup(of: WireRecommendationHydrationCounts.self) { group in
      group.addTask { try await self.hydrateBatch(asOf: asOf, limit: limit) }
      group.addTask {
        try await Task.sleep(for: .seconds(120))
        throw HydrationError.batchDeadline
      }
      defer { group.cancelAll() }
      guard let result = try await group.next() else { throw HydrationError.batchDeadline }
      return result
    }
  }

  private func hydrateBatch(asOf: Date, limit: Int) async throws -> WireRecommendationHydrationCounts {
    let started = ContinuousClock.now
    seedCursor = try await store.seed(after: seedCursor, asOf: asOf)
    var remaining = min(16, max(1, limit))
    var counts = WireRecommendationHydrationCounts()
    while remaining > 0 {
      let now = Self.elapsedTime(asOf: asOf, since: started)
      // Claim only execution slots, not the entire batch: a slow PDS cannot let
      // later queued jobs' durable leases expire before those jobs even start.
      let jobs = try await store.claim(asOf: now, limit: min(2, remaining))
      guard !jobs.isEmpty else { break }
      let batch = try await withThrowingTaskGroup(of: WireRecommendationHydrationCounts.self) { group in
        for job in jobs { group.addTask { try await self.hydrate(job, asOf: now) } }
        var results = WireRecommendationHydrationCounts()
        while let result = try await group.next() { results.add(result) }
        return results
      }
      counts.add(batch)
      remaining -= jobs.count
    }
    return counts
  }

  private func hydrate(_ job: WireRecommendationHydrationJob, asOf: Date) async throws -> WireRecommendationHydrationCounts {
    var counts = WireRecommendationHydrationCounts(attempted: 1)
    let started = ContinuousClock.now
    do {
      guard let expectedCID = job.expectedCID, !expectedCID.isEmpty,
        let subject = job.subjectURI, !subject.isEmpty
      else {
        _ = try await store.observe(job, status: "unsupported", cid: nil, subject: nil,
          revision: nil, observedAt: nil, reason: "missing_original_identity", asOf: Self.elapsedTime(asOf: asOf, since: started))
        counts.unavailable = 1
        return counts
      }
      let result = try await verify(job.sourceURI, expectedCID: expectedCID)
      switch result {
      case .verified(let record):
        guard record.uri == job.sourceURI, record.cid == expectedCID,
          let original = try JSONSerialization.jsonObject(with: record.recordJSON) as? [String: Any],
          PostgresWireInboxProcessor.referenceSubjectURI(record: original, collection: "site.standard.graph.recommend") == subject
        else {
          try await store.postpone(job, reason: "verified_subject_mismatch", asOf: Self.elapsedTime(asOf: asOf, since: started))
          counts.unavailable = 1
          return counts
        }
        guard try await store.observe(job, status: "verified", cid: record.cid, subject: subject,
          revision: record.repositoryRevision, observedAt: record.observedAt, reason: nil, asOf: Self.elapsedTime(asOf: asOf, since: started))
        else { counts.superseded = 1; return counts }
        counts.verified = 1
        if !(try await store.hasAlias(subject, asOf: Self.elapsedTime(asOf: asOf, since: started))) {
          counts.staged = try await hydrateSubject(subject, for: job, asOf: Self.elapsedTime(asOf: asOf, since: started))
        }
        try await store.wake(job, asOf: Self.elapsedTime(asOf: asOf, since: started))
      case .missing(let observation):
        _ = try await store.observe(job, status: "absent", cid: nil, subject: subject,
          revision: observation.repositoryRevision, observedAt: observation.observedAt,
          reason: "authoritative_record_absent", asOf: Self.elapsedTime(asOf: asOf, since: started))
        counts.unavailable = 1
      case .changed(let currentCID, let observation):
        _ = try await store.observe(job, status: "changed", cid: currentCID, subject: subject,
          revision: observation.repositoryRevision, observedAt: observation.observedAt,
          reason: "authoritative_record_changed", asOf: Self.elapsedTime(asOf: asOf, since: started))
        counts.unavailable = 1
      case .inactive(let observation):
        _ = try await store.observe(job, status: "inactive", cid: nil, subject: subject,
          revision: observation.repositoryRevision, observedAt: observation.observedAt,
          reason: "authoritative_repo_inactive", asOf: Self.elapsedTime(asOf: asOf, since: started))
        counts.unavailable = 1
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      try Task.checkCancellation()
      let reason: String
      switch error {
      case HydrationError.subjectRecordAbsent: reason = "subject_record_absent"
      case HydrationError.subjectRepoInactive: reason = "subject_repo_inactive"
      default: reason = "dependency_fetch_unavailable"
      }
      try await store.postpone(job, reason: reason, asOf: Self.elapsedTime(asOf: asOf, since: started))
      counts.unavailable = 1
    }
    return counts
  }

  private func hydrateSubject(_ subject: String, for job: WireRecommendationHydrationJob, asOf: Date) async throws -> Int {
    if let task = subjects[subject] { _ = try await task.value; return 0 }
    let task = Task { try await self.fetchAndProject(subject, for: job, asOf: asOf) }
    subjects[subject] = task
    defer { subjects.removeValue(forKey: subject) }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private func fetchAndProject(_ subject: String, for job: WireRecommendationHydrationJob, asOf: Date) async throws -> Int {
    let started = ContinuousClock.now
    let document: WireVerifiedPublicRecord
    switch try await verify(subject, expectedCID: nil) {
    case .verified(let value): document = value
    case .missing: throw HydrationError.subjectRecordAbsent
    case .inactive: throw HydrationError.subjectRepoInactive
    case .changed: throw HydrationError.unavailableSubject
    }
    guard ["site.standard.document", "site.standard.entry"].contains(document.collection), document.uri == subject,
      let value = try JSONSerialization.jsonObject(with: document.recordJSON) as? [String: Any]
    else { throw HydrationError.unavailableSubject }
    var records: [WireVerifiedPublicRecord] = []
    if let site = value["site"] as? String, site.hasPrefix("at://") {
      guard case .verified(let publication) = try await verify(site, expectedCID: nil),
        publication.uri == site, publication.collection == "site.standard.publication"
      else { throw HydrationError.unavailablePublication }
      records.append(publication)
    }
    records.append(document)
    try Task.checkCancellation()
    let events = try await store.stage(records, for: job, asOf: Self.elapsedTime(asOf: asOf, since: started))
    for event in events {
      try Task.checkCancellation()
      let outcome = try await processor.applyClaimed(event, asOf: Self.elapsedTime(asOf: asOf, since: started))
      guard outcome == .applied else { throw HydrationError.projectionUnavailable }
    }
    return events.count
  }

  private func verify(_ uri: String, expectedCID: String?) async throws -> WirePublicRecordVerification {
    let verifier = verifier
    return try await withThrowingTaskGroup(of: WirePublicRecordVerification.self) { group in
      group.addTask { try await verifier.verify(uri: uri, expectedCID: expectedCID) }
      group.addTask {
        try await Task.sleep(for: .seconds(45))
        throw HydrationError.timeout
      }
      defer { group.cancelAll() }
      guard let result = try await group.next() else { throw HydrationError.timeout }
      return result
    }
  }

  private static func elapsedTime(asOf: Date, since start: ContinuousClock.Instant) -> Date {
    let elapsed = start.duration(to: .now).components
    return asOf.addingTimeInterval(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
  }

  private enum HydrationError: Error {
    case unavailableSubject, unavailablePublication, projectionUnavailable, timeout, batchDeadline
    case subjectRecordAbsent, subjectRepoInactive
  }
}
