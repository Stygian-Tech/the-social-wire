import Foundation
import Testing

@testable import ThinAppViewCore

@Suite("PDS reconciliation scope")
struct PDSReconciliationScopeTests {
  private let aliceDid = "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa"
  private let bobDid = "did:plc:bbbbbbbbbbbbbbbbbbbbbbbb"

  @Test("requested and accepted DID scope is exact and deterministic")
  func exactScope() {
    let evidence = ThinAppViewEnrollBackfill.validateAuthorScope(
      [" \(bobDid) ", aliceDid, "did:web:profiles.thesocialwire.app:users:carol"],
      maximumAuthors: 10
    )
    #expect(
      evidence.requestedAuthorDids
        == [" \(bobDid) ", aliceDid, "did:web:profiles.thesocialwire.app:users:carol"]
    )
    #expect(
      evidence.acceptedAuthorDids
        == [aliceDid, bobDid, "did:web:profiles.thesocialwire.app:users:carol"]
    )
    #expect(evidence.issues.isEmpty)
    #expect(evidence.isAccepted)
  }

  @Test("invalid or duplicate DIDs reject the entire diagnostic scope")
  func invalidAndDuplicateScope() {
    let evidence = ThinAppViewEnrollBackfill.validateAuthorScope(
      [aliceDid, " \(aliceDid) ", "not-a-did", "did:web:example.com::synthetic"],
      maximumAuthors: 10
    )
    #expect(evidence.acceptedAuthorDids.isEmpty)
    #expect(evidence.issues.map(\.kind).contains(.duplicateDid))
    #expect(evidence.issues.map(\.kind).filter { $0 == .invalidDid }.count == 2)
    #expect(!evidence.isAccepted)
  }

  @Test("over-limit DID scope is rejected instead of prefix-truncated")
  func overLimitScope() {
    let evidence = ThinAppViewEnrollBackfill.validateAuthorScope(
      [aliceDid, bobDid],
      maximumAuthors: 1
    )
    #expect(evidence.acceptedAuthorDids.isEmpty)
    #expect(evidence.issues == [
      PDSAuthorScopeIssue(kind: .authorLimitExceeded, value: "requested=2;maximum=1")
    ])
  }

  @Test("accepts safe did:web repository forms and rejects synthetic or unsafe values")
  func webRepositoryDIDs() {
    #expect(
      ThinAppViewEnrollBackfill.isBackfillEligibleAuthorDid(
        "did:web:profiles.thesocialwire.app:users:alice"
      )
    )
    #expect(!ThinAppViewEnrollBackfill.isBackfillEligibleAuthorDid("did:web:localhost"))
    #expect(
      !ThinAppViewEnrollBackfill.isBackfillEligibleAuthorDid(
        "did:web:localhost%3A3000:users:alice"
      )
    )
    #expect(!ThinAppViewEnrollBackfill.isBackfillEligibleAuthorDid("did:web:127.0.0.1"))
    #expect(!ThinAppViewEnrollBackfill.isBackfillEligibleAuthorDid("did:web:example.com"))
    #expect(!ThinAppViewEnrollBackfill.isBackfillEligibleAuthorDid("did:web:skyreader.rss"))
    #expect(!ThinAppViewEnrollBackfill.isBackfillEligibleAuthorDid("did:web:example.com::alice"))
    #expect(!ThinAppViewEnrollBackfill.isBackfillEligibleAuthorDid("did:web:example.com:%2Fadmin"))
    #expect(!ThinAppViewEnrollBackfill.isBackfillEligibleAuthorDid("did:web:user@example.com"))
  }

  @Test("record cap is shared across every collection for one author")
  func capIsPerAuthor() {
    var budget = PDSAuthorRecordBudget(limit: 5)
    budget.consume(3)
    #expect(budget.remaining == 2)
    budget.consume(2)
    #expect(budget.remaining == 0)
    budget.consume(100)
    #expect(budget.consumed == 5)
  }

  @Test("diagnostic outcomes become normalized durable author results")
  func durableAuthorResults() {
    let report = PDSReconciliationReport(
      authorScope: PDSAuthorScopeEvidence(
        requestedAuthorDids: [aliceDid],
        acceptedAuthorDids: [aliceDid],
        issues: []
      ),
      limits: PDSReconciliationLimitsEvidence(
        maximumAuthors: 10,
        recordCapPerAuthor: 50,
        maxConcurrency: 1,
        rateLimitPerSecond: 10,
        maxRateLimitRetries: 3
      ),
      authors: [
        PDSAuthorReconciliationResult(
          authorDid: aliceDid,
          pdsBase: "https://pds.thesocialwire.app",
          collections: [
            PDSCollectionReconciliationResult(
              collection: "site.standard.document",
              observedCount: 3,
              indexedCount: 2,
              truncated: true,
              issues: [
                .init(kind: .malformedRecord, detail: "detail_must_not_escape"),
                .init(kind: .recordCapReached, detail: "record_cap_per_author"),
              ]
            )
          ],
          issues: []
        )
      ],
      unsupportedCollections: ["legacy.unregistered.collection"],
      historicalDeletesProvable: false
    )

    let results = ThinAppViewRecoveryJobRunner.authorResults(report)
    #expect(results.count == 2)
    #expect(results[0].did == aliceDid)
    #expect(results[0].collection == "legacy.unregistered.collection")
    #expect(results[0].status == .unsupported)
    #expect(results[1].discoveredCount == 3)
    #expect(results[1].processedCount == 2)
    #expect(results[1].failedCount == 1)
    #expect(results[1].capped)
    #expect(results[1].truncated)
    #expect(results[1].status == .partial)
    #expect(results[1].error == "malformed_record,record_cap_reached")
    #expect(results[1].error?.contains("detail_must_not_escape") == false)
  }
}

@Suite("PDS reconciliation rate limiting")
struct PDSReconciliationRateLimitTests {
  @Test("concurrent callers reserve distinct permits before suspension")
  func concurrentPermitsRemainRateLimited() async throws {
    let sleeper = GatedPermitSleeper()
    let limiter = PDSRequestRateLimiter(
      requestsPerSecond: 20,
      now: { Date(timeIntervalSinceReferenceDate: 0) },
      sleep: { await sleeper.suspend(for: $0) })
    let callers = Task {
      try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<5 {
          group.addTask { try await limiter.waitForPermit() }
        }
        try await group.waitForAll()
      }
    }
    await sleeper.waitForSuspendedPermits()
    let delays = await sleeper.delays.sorted()
    #expect(delays.count == 4)
    for (actual, expected) in zip(delays, [0.05, 0.10, 0.15, 0.20]) {
      #expect(abs(actual - expected) < 0.000_001)
    }
    await sleeper.releaseAll()
    try await callers.value
  }

  @Test("Retry-After delta seconds is parsed, jittered, and capped")
  func retryAfterDeltaSeconds() {
    let evidence = PDSRateLimitRetryPolicy.evidence(
      attempt: 1,
      retryAfterValue: "120",
      now: Date(timeIntervalSince1970: 0),
      jitterFraction: 0.20,
      willRetry: true
    )
    #expect(evidence.source == .retryAfterDeltaSeconds)
    #expect(evidence.baseDelaySeconds == 120)
    #expect(evidence.jitterSeconds == 24)
    #expect(evidence.appliedDelaySeconds == 30)
    #expect(evidence.capped)
    #expect(evidence.outcome == .scheduled)
  }

  @Test("Retry-After HTTP-date is parsed and bounded with visible jitter")
  func retryAfterHTTPDate() {
    let evidence = PDSRateLimitRetryPolicy.evidence(
      attempt: 1,
      retryAfterValue: "Thu, 01 Jan 1970 00:00:20 GMT",
      now: Date(timeIntervalSince1970: 0),
      jitterFraction: 0.10,
      willRetry: true
    )
    #expect(evidence.source == .retryAfterHTTPDate)
    #expect(evidence.baseDelaySeconds == 20)
    #expect(evidence.jitterSeconds == 2)
    #expect(evidence.appliedDelaySeconds == 22)
    #expect(!evidence.capped)
  }

  @Test("invalid Retry-After uses exponential backoff and exhausted retries do not sleep")
  func invalidAndExhaustedRetryAfter() {
    let fallback = PDSRateLimitRetryPolicy.evidence(
      attempt: 3,
      retryAfterValue: "not-a-delay",
      now: Date(timeIntervalSince1970: 0),
      jitterFraction: 0.25,
      willRetry: true
    )
    #expect(fallback.source == .exponentialBackoff)
    #expect(fallback.baseDelaySeconds == 4)
    #expect(fallback.jitterSeconds == 1)
    #expect(fallback.appliedDelaySeconds == 5)

    let exhausted = PDSRateLimitRetryPolicy.evidence(
      attempt: 4,
      retryAfterValue: "10",
      now: Date(timeIntervalSince1970: 0),
      jitterFraction: 0.20,
      willRetry: false
    )
    #expect(exhausted.outcome == .exhausted)
    #expect(exhausted.appliedDelaySeconds == 0)
    #expect(exhausted.jitterSeconds == 0)
  }
}

private actor GatedPermitSleeper {
  private(set) var delays: [TimeInterval] = []
  private var permits: [CheckedContinuation<Void, Never>] = []
  private var observer: CheckedContinuation<Void, Never>?

  func suspend(for delay: TimeInterval) async {
    await withCheckedContinuation { continuation in
      delays.append(delay)
      permits.append(continuation)
      if permits.count == 4 {
        observer?.resume()
        observer = nil
      }
    }
  }

  func waitForSuspendedPermits() async {
    if permits.count == 4 { return }
    await withCheckedContinuation { observer = $0 }
  }

  func releaseAll() {
    let ready = permits
    permits.removeAll()
    for permit in ready { permit.resume() }
  }
}
