import AsyncHTTPClient
import Foundation
import Logging
import NIOCore
import OperationsCore

public struct PDSReconciliationOptions: Sendable, Equatable {
  public let recentOnly: Bool
  public let maxConcurrency: Int
  public let rateLimitPerSecond: Int
  public let recordCapPerAuthor: Int
  public let maxRateLimitRetries: Int

  public init(
    recentOnly: Bool = false,
    maxConcurrency: Int,
    rateLimitPerSecond: Int,
    recordCapPerAuthor: Int,
    maxRateLimitRetries: Int = 3
  ) {
    self.recentOnly = recentOnly
    self.maxConcurrency = max(1, maxConcurrency)
    self.rateLimitPerSecond = max(1, rateLimitPerSecond)
    self.recordCapPerAuthor = max(1, recordCapPerAuthor)
    self.maxRateLimitRetries = max(0, maxRateLimitRetries)
  }
}

public struct PDSReconciliationLimitsEvidence: Codable, Sendable, Equatable {
  public let maximumAuthors: Int
  public let recordCapPerAuthor: Int
  public let maxConcurrency: Int
  public let rateLimitPerSecond: Int
  public let maxRateLimitRetries: Int
}

public enum PDSReconciliationIssueKind: String, Codable, Sendable, Equatable {
  case pdsResolutionFailed = "pds_resolution_failed"
  case requestFailed = "request_failed"
  case rateLimitExhausted = "rate_limit_exhausted"
  case unexpectedStatus = "unexpected_status"
  case malformedResponse = "malformed_response"
  case malformedRecord = "malformed_record"
  case recordCapReached = "record_cap_reached"
  case cancelled
  case unsupportedCollection = "unsupported_collection"
}

public enum PDSAuthorScopeIssueKind: String, Codable, Sendable, Equatable {
  case emptyScope = "empty_author_scope"
  case invalidDid = "invalid_author_did"
  case duplicateDid = "duplicate_author_did"
  case authorLimitExceeded = "author_limit_exceeded"
}

public struct PDSAuthorScopeIssue: Codable, Sendable, Equatable {
  public let kind: PDSAuthorScopeIssueKind
  public let value: String

  public init(kind: PDSAuthorScopeIssueKind, value: String) {
    self.kind = kind
    self.value = value
  }
}

public struct PDSAuthorScopeEvidence: Codable, Sendable, Equatable {
  public let requestedAuthorDids: [String]
  public let acceptedAuthorDids: [String]
  public let issues: [PDSAuthorScopeIssue]

  public var isAccepted: Bool { issues.isEmpty && !acceptedAuthorDids.isEmpty }
}

public struct PDSReconciliationIssue: Codable, Sendable, Equatable {
  public let kind: PDSReconciliationIssueKind
  public let detail: String

  public init(kind: PDSReconciliationIssueKind, detail: String) {
    self.kind = kind
    self.detail = detail
  }
}

public struct PDSCollectionReconciliationResult: Codable, Sendable, Equatable {
  public let collection: String
  public let observedCount: Int
  public let indexedCount: Int
  public let truncated: Bool
  public let issues: [PDSReconciliationIssue]
  /// Optional for backward-compatible decoding of recovery results stored before retry evidence.
  public let rateLimitRetries: [PDSRateLimitRetryEvidence]?

  public init(
    collection: String,
    observedCount: Int,
    indexedCount: Int,
    truncated: Bool,
    issues: [PDSReconciliationIssue],
    rateLimitRetries: [PDSRateLimitRetryEvidence] = []
  ) {
    self.collection = collection
    self.observedCount = observedCount
    self.indexedCount = indexedCount
    self.truncated = truncated
    self.issues = issues
    self.rateLimitRetries = rateLimitRetries
  }
}

public enum PDSRateLimitDelaySource: String, Codable, Sendable, Equatable {
  case retryAfterDeltaSeconds = "retry_after_delta_seconds"
  case retryAfterHTTPDate = "retry_after_http_date"
  case exponentialBackoff = "exponential_backoff"
}

public enum PDSRateLimitRetryOutcome: String, Codable, Sendable, Equatable {
  case scheduled
  case exhausted
}

/// The exact bounded delay selected for one HTTP 429 response.
///
/// This is included in the per-author reconciliation result so rate limiting is observable rather
/// than disappearing inside a successful request retry.
public struct PDSRateLimitRetryEvidence: Codable, Sendable, Equatable {
  public let attempt: Int
  public let source: PDSRateLimitDelaySource
  public let retryAfterValue: String?
  public let baseDelaySeconds: Double
  public let jitterSeconds: Double
  public let appliedDelaySeconds: Double
  public let capped: Bool
  public let outcome: PDSRateLimitRetryOutcome
}

public struct PDSAuthorReconciliationResult: Codable, Sendable, Equatable {
  public let authorDid: String
  public let pdsBase: String?
  public let collections: [PDSCollectionReconciliationResult]
  public let issues: [PDSReconciliationIssue]

  public var indexedCount: Int { collections.reduce(0) { $0 + $1.indexedCount } }
  public var truncated: Bool { collections.contains(where: \.truncated) }
  public var failed: Bool {
    !issues.isEmpty || collections.contains { !$0.issues.isEmpty }
  }
}

public struct PDSReconciliationReport: Codable, Sendable, Equatable {
  public let authorScope: PDSAuthorScopeEvidence
  public let limits: PDSReconciliationLimitsEvidence
  public let authors: [PDSAuthorReconciliationResult]
  public let unsupportedCollections: [String]
  public let historicalDeletesProvable: Bool

  public var indexedCount: Int { authors.reduce(0) { $0 + $1.indexedCount } }
  public var failedAuthorCount: Int { authors.filter(\.failed).count }
  public var truncated: Bool {
    authorScope.issues.contains { $0.kind == .authorLimitExceeded }
      || authors.contains(where: \.truncated)
  }
  public var complete: Bool {
    authorScope.isAccepted
      && unsupportedCollections.isEmpty
      && failedAuthorCount == 0
      && !truncated
  }
}

public struct PDSReconciliationProgress: Sendable, Equatable {
  public let authorDid: String
  public let collection: String
  public let indexedCount: Int
  public let lastRecordUri: String
}

public struct PDSReconciliationIncompleteError: Error, Sendable {
  public let report: PDSReconciliationReport
}

/// PDS `listRecords` reconciliation shared by AppView enrollment and diagnostic recovery.
///
/// This can prove which current records were observed. It cannot prove historical deletes and is
/// therefore never sufficient, by itself, to resolve an ingestion gap.
public struct ThinAppViewEnrollBackfill: Sendable {
  private let store: any ThinAppViewStore
  private let indexer: ThinAppViewIndexer
  private let httpTransport: any PDSHTTPTransport
  private let endpointPolicy: PDSResolvedEndpointPolicy
  private let plcURL: String
  private let config: ThinAppViewConfig
  private let logger: Logger

  public init(
    store: any ThinAppViewStore,
    indexer: ThinAppViewIndexer,
    httpClient: HTTPClient,
    plcURL: String,
    config: ThinAppViewConfig,
    logger: Logger
  ) {
    self.init(
      store: store,
      indexer: indexer,
      httpTransport: LivePDSHTTPTransport(httpClient: httpClient),
      endpointPolicy: .publicHTTPS,
      plcURL: plcURL,
      config: config,
      logger: logger
    )
  }

  init(
    store: any ThinAppViewStore,
    indexer: ThinAppViewIndexer,
    httpTransport: any PDSHTTPTransport,
    endpointPolicy: PDSResolvedEndpointPolicy,
    plcURL: String,
    config: ThinAppViewConfig,
    logger: Logger
  ) {
    self.store = store
    self.indexer = indexer
    self.httpTransport = httpTransport
    self.endpointPolicy = endpointPolicy
    self.plcURL = plcURL
    self.config = config
    self.logger = logger
  }

  /// Compatibility wrapper for enrollment. Full enrollment now fails loudly on partial results.
  public func enroll(
    authorDids: [String],
    collections: [String] = ThinAppViewConfig.canonicalContentCollections,
    recentOnly: Bool = false,
    shouldContinue: @Sendable @escaping () async -> Bool = { true }
  ) async throws -> Int {
    let report = try await reconcile(
      authorDids: authorDids,
      collections: collections,
      options: PDSReconciliationOptions(
        recentOnly: recentOnly,
        maxConcurrency: config.maxEnrollConcurrency,
        rateLimitPerSecond: max(1, config.maxEnrollConcurrency * 10),
        recordCapPerAuthor: config.maxEnrollRecordsPerAuthor
      ),
      shouldContinue: shouldContinue
    )
    if !recentOnly, !report.complete {
      throw PDSReconciliationIncompleteError(report: report)
    }
    return report.indexedCount
  }

  public func reconcile(
    authorDids: [String],
    collections: [String] = ThinAppViewConfig.canonicalContentCollections,
    options: PDSReconciliationOptions,
    shouldContinue: @Sendable @escaping () async -> Bool = { true },
    onProgress: @Sendable @escaping (PDSReconciliationProgress) async -> Void = { _ in }
  ) async throws -> PDSReconciliationReport {
    try Task.checkCancellation()
    let authorScope = Self.validateAuthorScope(
      authorDids,
      maximumAuthors: config.maxEnrollAuthors
    )
    let authors = authorScope.isAccepted ? authorScope.acceptedAuthorDids : []
    let limits = PDSReconciliationLimitsEvidence(
      maximumAuthors: config.maxEnrollAuthors,
      recordCapPerAuthor: options.recordCapPerAuthor,
      maxConcurrency: options.maxConcurrency,
      rateLimitPerSecond: options.rateLimitPerSecond,
      maxRateLimitRetries: options.maxRateLimitRetries
    )

    let requestedCollections = Array(
      Set(collections.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
    ).sorted()
    let supportedCollections = requestedCollections.filter {
      ThinAppViewConfig.canonicalContentCollections.contains($0)
    }
    let unsupportedCollections = requestedCollections.filter {
      !ThinAppViewConfig.canonicalContentCollections.contains($0)
    }
    guard !authors.isEmpty else {
      return PDSReconciliationReport(
        authorScope: authorScope,
        limits: limits,
        authors: [],
        unsupportedCollections: unsupportedCollections,
        historicalDeletesProvable: false
      )
    }

    let limiter = PDSRequestRateLimiter(requestsPerSecond: options.rateLimitPerSecond)
    let rateLimitedTransport = RateLimitedPDSHTTPTransport(
      upstream: httpTransport,
      limiter: limiter
    )
    var iterator = authors.makeIterator()
    var results: [PDSAuthorReconciliationResult] = []
    try await withThrowingTaskGroup(of: PDSAuthorReconciliationResult.self) { group in
      var inFlight = 0
      func enqueueNext() {
        guard inFlight < options.maxConcurrency, let authorDid = iterator.next() else { return }
        inFlight += 1
        group.addTask {
          try await reconcileAuthor(
            authorDid: authorDid,
            collections: supportedCollections,
            options: options,
            transport: rateLimitedTransport,
            shouldContinue: shouldContinue,
            onProgress: onProgress
          )
        }
      }

      for _ in 0..<options.maxConcurrency { enqueueNext() }
      while inFlight > 0 {
        if let result = try await group.next() { results.append(result) }
        inFlight -= 1
        enqueueNext()
      }
    }

    let report = PDSReconciliationReport(
      authorScope: authorScope,
      limits: limits,
      authors: results.sorted { $0.authorDid < $1.authorDid },
      unsupportedCollections: unsupportedCollections,
      historicalDeletesProvable: false
    )
    logger.info(
      "PDS reconciliation finished",
      metadata: [
        "authors": .stringConvertible(report.authors.count),
        "requested_authors": .stringConvertible(report.authorScope.requestedAuthorDids.count),
        "scope_accepted": .stringConvertible(report.authorScope.isAccepted),
        "records": .stringConvertible(report.indexedCount),
        "failed_authors": .stringConvertible(report.failedAuthorCount),
        "truncated": .stringConvertible(report.truncated),
        "historical_deletes_provable": "false",
      ]
    )
    return report
  }

  public func diagnosticOptions(
    maxConcurrency: Int,
    rateLimitPerSecond: Int
  ) -> PDSReconciliationOptions {
    PDSReconciliationOptions(
      maxConcurrency: maxConcurrency,
      rateLimitPerSecond: rateLimitPerSecond,
      recordCapPerAuthor: config.maxEnrollRecordsPerAuthor
    )
  }

  public static func isBackfillEligibleAuthorDid(_ raw: String) -> Bool {
    ATProtoRepositoryDIDValidator.isValid(raw)
  }

  public static func validateAuthorScope(
    _ authorDids: [String],
    maximumAuthors: Int
  ) -> PDSAuthorScopeEvidence {
    var issues: [PDSAuthorScopeIssue] = []
    var unique: Set<String> = []
    var candidates: [String] = []
    for requested in authorDids {
      let normalized = requested.trimmingCharacters(in: .whitespacesAndNewlines)
      guard isBackfillEligibleAuthorDid(normalized) else {
        issues.append(
          .init(kind: .invalidDid, value: normalized.isEmpty ? "<empty>" : normalized)
        )
        continue
      }
      guard unique.insert(normalized).inserted else {
        issues.append(.init(kind: .duplicateDid, value: normalized))
        continue
      }
      candidates.append(normalized)
    }
    if authorDids.isEmpty {
      issues.append(.init(kind: .emptyScope, value: "0"))
    }
    let maximumAuthors = max(1, maximumAuthors)
    if candidates.count > maximumAuthors {
      issues.append(
        .init(
          kind: .authorLimitExceeded,
          value: "requested=\(candidates.count);maximum=\(maximumAuthors)"
        )
      )
    }
    return PDSAuthorScopeEvidence(
      requestedAuthorDids: authorDids,
      acceptedAuthorDids: issues.isEmpty ? candidates.sorted() : [],
      issues: issues
    )
  }

  private func reconcileAuthor(
    authorDid: String,
    collections: [String],
    options: PDSReconciliationOptions,
    transport: any PDSHTTPTransport,
    shouldContinue: @Sendable @escaping () async -> Bool,
    onProgress: @Sendable @escaping (PDSReconciliationProgress) async -> Void
  ) async throws -> PDSAuthorReconciliationResult {
    try Task.checkCancellation()
    guard await shouldContinue() else {
      return PDSAuthorReconciliationResult(
        authorDid: authorDid,
        pdsBase: nil,
        collections: [],
        issues: [.init(kind: .cancelled, detail: "cancelled_before_resolution")]
      )
    }

    let pds: String
    do {
      guard let resolved = try await ThinAppViewPdsResolution.resolvePdsBase(
        repoDid: authorDid,
        plcBase: plcURL,
        transport: transport,
        endpointPolicy: endpointPolicy
      ) else {
        return PDSAuthorReconciliationResult(
          authorDid: authorDid,
          pdsBase: nil,
          collections: [],
          issues: [.init(kind: .pdsResolutionFailed, detail: "no_pds_service")]
        )
      }
      pds = resolved
    } catch {
      try Task.checkCancellation()
      return PDSAuthorReconciliationResult(
        authorDid: authorDid,
        pdsBase: nil,
        collections: [],
        issues: [.init(kind: .pdsResolutionFailed, detail: errorCategory(error))]
      )
    }

    var collectionResults: [PDSCollectionReconciliationResult] = []
    var recordBudget = PDSAuthorRecordBudget(limit: options.recordCapPerAuthor)
    for collection in collections {
      try Task.checkCancellation()
      guard await shouldContinue() else {
        return PDSAuthorReconciliationResult(
          authorDid: authorDid,
          pdsBase: pds,
          collections: collectionResults,
          issues: [.init(kind: .cancelled, detail: "cancelled_between_collections")]
        )
      }
      guard recordBudget.remaining > 0 else {
        collectionResults.append(
          PDSCollectionReconciliationResult(
            collection: collection,
            observedCount: 0,
            indexedCount: 0,
            truncated: true,
            issues: [.init(kind: .recordCapReached, detail: "record_cap_per_author")]
          )
        )
        continue
      }
      let result = try await reconcileCollection(
        authorDid: authorDid,
        pdsBase: pds,
        collection: collection,
        options: options,
        recordBudget: recordBudget.remaining,
        transport: transport,
        shouldContinue: shouldContinue,
        onProgress: onProgress
      )
      collectionResults.append(result)
      recordBudget.consume(result.observedCount)
    }
    return PDSAuthorReconciliationResult(
      authorDid: authorDid,
      pdsBase: pds,
      collections: collectionResults,
      issues: []
    )
  }

  private func reconcileCollection(
    authorDid: String,
    pdsBase: String,
    collection: String,
    options: PDSReconciliationOptions,
    recordBudget: Int,
    transport: any PDSHTTPTransport,
    shouldContinue: @Sendable @escaping () async -> Bool,
    onProgress: @Sendable @escaping (PDSReconciliationProgress) async -> Void
  ) async throws -> PDSCollectionReconciliationResult {
    var cursor: String?
    var seenCursors: Set<String> = []
    var observedCount = 0
    var count = 0
    var issues: [PDSReconciliationIssue] = []
    var truncated = false
    var rateLimitRetries: [PDSRateLimitRetryEvidence] = []

    pageLoop: repeat {
      try Task.checkCancellation()
      guard await shouldContinue() else {
        issues.append(.init(kind: .cancelled, detail: "cancelled_during_collection"))
        break
      }
      let response: HTTPClientResponse
      do {
        let result = try await listRecordsResponse(
          authorDid: authorDid,
          pdsBase: pdsBase,
          collection: collection,
          cursor: cursor,
          options: options,
          transport: transport
        )
        response = result.response
        rateLimitRetries.append(contentsOf: result.rateLimitRetries)
      } catch let error as PDSListRecordsError {
        rateLimitRetries.append(contentsOf: error.rateLimitRetries)
        issues.append(error.issue)
        break
      } catch {
        try Task.checkCancellation()
        issues.append(.init(kind: .requestFailed, detail: errorCategory(error)))
        break
      }

      let body: ByteBuffer
      do {
        body = try await response.body.collect(upTo: 512 * 1_024)
      } catch {
        try Task.checkCancellation()
        issues.append(.init(kind: .malformedResponse, detail: "body_too_large_or_unreadable"))
        break
      }
      try Task.checkCancellation()
      guard
        let json = try? JSONSerialization.jsonObject(with: Data(buffer: body)) as? [String: Any],
        let records = json["records"] as? [[String: Any]]
      else {
        issues.append(.init(kind: .malformedResponse, detail: "records_array_missing"))
        break
      }

      for row in records {
        try Task.checkCancellation()
        guard await shouldContinue() else {
          issues.append(.init(kind: .cancelled, detail: "cancelled_during_page"))
          break
        }
        if observedCount >= recordBudget {
          truncated = true
          issues.append(.init(kind: .recordCapReached, detail: "record_cap_per_author"))
          break
        }
        observedCount += 1
        guard
          let uri = row["uri"] as? String,
          let cid = row["cid"] as? String,
          let value = row["value"],
          let parsed = RenderFieldExtractor.parseAtUri(uri),
          parsed.did == authorDid,
          parsed.collection == collection,
          JSONSerialization.isValidJSONObject(value),
          let recordJSON = try? JSONSerialization.data(withJSONObject: value)
        else {
          issues.append(.init(kind: .malformedRecord, detail: "invalid_record_envelope"))
          continue
        }

        do {
          try await indexer.handleCommit(
            repoDid: parsed.did,
            collection: parsed.collection,
            rkey: parsed.rkey,
            cid: cid,
            recordJSON: recordJSON,
            operation: "create",
            pdsBase: pdsBase,
            ingestionSource: "pds_reconciliation"
          )
          count += 1
          await onProgress(
            PDSReconciliationProgress(
              authorDid: authorDid,
              collection: collection,
              indexedCount: count,
              lastRecordUri: uri
            )
          )
        } catch {
          try Task.checkCancellation()
          issues.append(.init(kind: .requestFailed, detail: "indexing_\(errorCategory(error))"))
        }
      }

      let nextCursor: String?
      switch PDSListRecordsCursor.parse(
        json: json,
        current: cursor,
        seen: seenCursors,
        pageIsEmpty: records.isEmpty
      ) {
      case .end:
        nextCursor = nil
      case .next(let value):
        nextCursor = value
      case .invalid(let reason):
        issues.append(.init(kind: .malformedResponse, detail: reason))
        break pageLoop
      }
      if options.recentOnly {
        truncated = nextCursor != nil
        break
      }
      if observedCount >= recordBudget, nextCursor != nil {
        truncated = true
        issues.append(.init(kind: .recordCapReached, detail: "record_cap_per_author"))
        break
      }
      if truncated || issues.contains(where: { $0.kind == .cancelled }) { break }
      if let nextCursor { seenCursors.insert(nextCursor) }
      cursor = nextCursor
    } while cursor != nil

    return PDSCollectionReconciliationResult(
      collection: collection,
      observedCount: observedCount,
      indexedCount: count,
      truncated: truncated,
      issues: issues,
      rateLimitRetries: rateLimitRetries
    )
  }

  private func listRecordsResponse(
    authorDid: String,
    pdsBase: String,
    collection: String,
    cursor: String?,
    options: PDSReconciliationOptions,
    transport: any PDSHTTPTransport
  ) async throws -> PDSListRecordsPageResponse {
    var attempts = 0
    var rateLimitRetries: [PDSRateLimitRetryEvidence] = []
    while true {
      try Task.checkCancellation()
      var components = URLComponents(
        string: "\(normalizePdsBase(pdsBase))/xrpc/com.atproto.repo.listRecords"
      )
      components?.queryItems = [
        URLQueryItem(name: "repo", value: authorDid),
        URLQueryItem(name: "collection", value: collection),
        URLQueryItem(name: "limit", value: "50"),
        URLQueryItem(name: "reverse", value: "true"),
      ] + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
      guard let url = components?.url else {
        throw PDSListRecordsError(
          issue: .init(kind: .requestFailed, detail: "invalid_list_records_url"),
          rateLimitRetries: rateLimitRetries
        )
      }
      var request = HTTPClientRequest(url: url.absoluteString)
      request.headers.add(name: "Accept", value: "application/json")
      let response = try await transport.execute(request, timeout: .seconds(20))
      if response.status.code == 429 {
        let retryAfterValue = response.headers.first(name: "Retry-After")
        try await HTTPResponseBodyDrain.drainOrCancel(response.body)
        let willRetry = attempts < options.maxRateLimitRetries
        let evidence = PDSRateLimitRetryPolicy.evidence(
          attempt: attempts + 1,
          retryAfterValue: retryAfterValue,
          now: Date(),
          jitterFraction: Double.random(in: 0.10...0.25),
          willRetry: willRetry
        )
        rateLimitRetries.append(evidence)
        guard willRetry else {
          throw PDSListRecordsError(
            issue: .init(
              kind: .rateLimitExhausted,
              detail: "http_429;attempts=\(attempts + 1)"
            ),
            rateLimitRetries: rateLimitRetries
          )
        }
        attempts += 1
        try await Task.sleep(for: .seconds(evidence.appliedDelaySeconds))
        continue
      }
      guard response.status == .ok else {
        try await HTTPResponseBodyDrain.drainOrCancel(response.body)
        throw PDSListRecordsError(
          issue: .init(kind: .unexpectedStatus, detail: "http_\(response.status.code)"),
          rateLimitRetries: rateLimitRetries
        )
      }
      return PDSListRecordsPageResponse(
        response: response,
        rateLimitRetries: rateLimitRetries
      )
    }
  }

  private func normalizePdsBase(_ raw: String) -> String {
    var base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") { base.removeLast() }
    return base
  }

  private func errorCategory(_ error: Error) -> String {
    String(describing: type(of: error))
  }
}

private struct PDSListRecordsPageResponse {
  let response: HTTPClientResponse
  let rateLimitRetries: [PDSRateLimitRetryEvidence]
}

private struct PDSListRecordsError: Error {
  let issue: PDSReconciliationIssue
  let rateLimitRetries: [PDSRateLimitRetryEvidence]
}

struct PDSAuthorRecordBudget: Sendable, Equatable {
  let limit: Int
  private(set) var consumed: Int = 0
  var remaining: Int { max(0, limit - consumed) }

  init(limit: Int) {
    self.limit = max(1, limit)
  }

  mutating func consume(_ count: Int) {
    consumed = min(limit, consumed + max(0, count))
  }
}

actor PDSRequestRateLimiter {
  private let interval: TimeInterval
  private var nextPermitAt = Date.distantPast

  init(requestsPerSecond: Int) {
    interval = 1 / Double(max(1, requestsPerSecond))
  }

  func waitForPermit() async throws {
    try Task.checkCancellation()
    let now = Date()
    let permitAt = max(nextPermitAt, now)

    // Reserve the next slot before suspending. Updating after sleep lets actor reentrancy give every
    // concurrent waiter the same timestamp and burst above the configured rate.
    nextPermitAt = permitAt.addingTimeInterval(interval)
    guard permitAt > now else { return }
    try await Task.sleep(for: .seconds(permitAt.timeIntervalSince(now)))
    try Task.checkCancellation()
  }
}

enum PDSRateLimitRetryPolicy {
  static let maximumDelaySeconds: TimeInterval = 30

  static func evidence(
    attempt: Int,
    retryAfterValue: String?,
    now: Date,
    jitterFraction: Double,
    willRetry: Bool
  ) -> PDSRateLimitRetryEvidence {
    let parsed = parseRetryAfter(retryAfterValue, now: now)
    let source = parsed?.source ?? .exponentialBackoff
    let baseDelay = parsed?.seconds ?? pow(2, Double(max(0, attempt - 1)))
    let boundedJitterFraction = min(0.25, max(0, jitterFraction))
    let jitter = willRetry ? baseDelay * boundedJitterFraction : 0
    let uncappedDelay = baseDelay + jitter
    let appliedDelay = willRetry ? min(maximumDelaySeconds, max(0, uncappedDelay)) : 0

    return PDSRateLimitRetryEvidence(
      attempt: max(1, attempt),
      source: source,
      retryAfterValue: retryAfterValue,
      baseDelaySeconds: baseDelay,
      jitterSeconds: jitter,
      appliedDelaySeconds: appliedDelay,
      capped: uncappedDelay > maximumDelaySeconds,
      outcome: willRetry ? .scheduled : .exhausted
    )
  }

  static func parseRetryAfter(
    _ rawValue: String?,
    now: Date
  ) -> (seconds: TimeInterval, source: PDSRateLimitDelaySource)? {
    guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }

    if value.allSatisfy(\.isNumber), let seconds = UInt64(value) {
      return (TimeInterval(seconds), .retryAfterDeltaSeconds)
    }

    for format in [
      "EEE',' dd MMM yyyy HH':'mm':'ss zzz",
      "EEEE',' dd-MMM-yy HH':'mm':'ss zzz",
      "EEE MMM d HH':'mm':'ss yyyy",
    ] {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.calendar = Calendar(identifier: .gregorian)
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = format
      if let date = formatter.date(from: value) {
        return (
          max(0, date.timeIntervalSince(now)),
          .retryAfterHTTPDate
        )
      }
    }
    return nil
  }
}
