import Crypto
import Foundation

public enum BackfillScopePolicy {
  public static let maximumAuthorDids = 500
  public static let syntheticRSSDid = "did:web:skyreader.rss"

  public static func normalized(_ request: BackfillDryRunRequest) throws -> BackfillDryRunRequest {
    if request.sourceMode != .pdsReconciliation, request.maxConcurrency != 1 {
      throw BackfillScopeValidationError.unsupportedConcurrency(
        sourceMode: request.sourceMode.rawValue)
    }
    let trimmed = request.authorDids.map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if request.sourceMode != .jetstreamReplay, trimmed.isEmpty {
      throw BackfillScopeValidationError.emptyAuthorScope
    }
    guard trimmed.count <= maximumAuthorDids else {
      throw BackfillScopeValidationError.authorScopeTooLarge(maximum: maximumAuthorDids)
    }
    guard Set(trimmed).count == trimmed.count else {
      throw BackfillScopeValidationError.duplicateAuthorDid
    }
    for did in trimmed {
      guard ATProtoRepositoryDIDValidator.isValid(did) else {
        throw BackfillScopeValidationError.invalidAuthorDid(did)
      }
    }
    return BackfillDryRunRequest(
      gapId: request.gapId,
      sourceMode: request.sourceMode,
      startCursor: request.startCursor,
      endCursor: request.endCursor,
      collections: request.collections,
      authorDids: trimmed.sorted(),
      batchSize: request.batchSize,
      rateLimit: request.rateLimit,
      maxConcurrency: request.maxConcurrency)
  }

}

public enum BackfillScopeValidationError: Error, Sendable, Equatable, LocalizedError {
  case emptyAuthorScope
  case authorScopeTooLarge(maximum: Int)
  case duplicateAuthorDid
  case invalidAuthorDid(String)
  case unsupportedConcurrency(sourceMode: String)

  public var errorDescription: String? {
    switch self {
    case .emptyAuthorScope: return "Tap and PDS recovery require at least one author DID."
    case .authorScopeTooLarge(let maximum):
      return "Author scope exceeds the maximum of \(maximum) DIDs."
    case .duplicateAuthorDid: return "Author scope contains duplicate DIDs."
    case .invalidAuthorDid(let did): return "Author scope contains an invalid or synthetic DID: \(did)"
    case .unsupportedConcurrency(let sourceMode):
      return "\(sourceMode) recovery currently requires maxConcurrency to be exactly 1."
    }
  }
}

enum BackfillDryRunAssessment {
  static func build(
    request: BackfillDryRunRequest,
    gap: IngestionGap?,
    existingJobs: [BackfillJob]
  ) -> BackfillDryRunResponse {
    var conflicts: [String] = []

    if request.gapId != nil {
      guard let gap else {
        return response(request: request, estimatedCount: 0, conflicts: [
          "The selected gap no longer exists. Refresh the Operations console before continuing."
        ])
      }
      if gap.status == .resolved || gap.status == .ignored {
        conflicts.append("The selected gap is already \(gap.status.rawValue) and does not need a backfill.")
      }
      if request.sourceMode == .jetstreamReplay,
        gap.startCursor != request.startCursor || gap.endCursor != request.endCursor
      {
        conflicts.append("The replay range no longer matches the selected gap. Refresh the dry run.")
      }
      let gapCollections = Set(gap.collections)
      if !gapCollections.isEmpty && gapCollections.isDisjoint(with: request.collections) {
        conflicts.append("The selected collections do not intersect the collections observed for this gap.")
      }
    }

    if existingJobs.contains(where: { overlaps($0, request: request) }) {
      conflicts.append("An active backfill already covers this recovery scope.")
    }

    return response(request: request, estimatedCount: modeledEstimate(for: request), conflicts: conflicts)
  }

  private static func response(
    request: BackfillDryRunRequest,
    estimatedCount: Int,
    conflicts: [String]
  ) -> BackfillDryRunResponse {
    let validUntil = Date().addingTimeInterval(120)
    let durationSeconds: Int
    let methodology: String
    switch request.sourceMode {
    case .jetstreamReplay:
      durationSeconds = request.rateLimit > 0
        ? Int(ceil(Double(estimatedCount) / Double(request.rateLimit))) : 0
      methodology = "modeled_cursor_density_v1"
    case .pdsReconciliation:
      // PDS rate limits are requests/sec. Model listRecords pages plus one bounded
      // repository/collection resolution request instead of treating records as requests.
      let pageRequests = Int(ceil(Double(estimatedCount) / 50.0))
      let resolutionRequests = request.authorDids.count
      durationSeconds = request.rateLimit > 0
        ? Int(ceil(Double(pageRequests + resolutionRequests) / Double(request.rateLimit)))
        : 0
      methodology = "modeled_pds_list_records_50_per_page_plus_author_resolution_v2"
    case .tapVerifiedResync:
      durationSeconds = 0
      methodology = "unavailable_pinned_tap_resync"
    }
    return BackfillDryRunResponse(
      estimatedCount: estimatedCount,
      estimatedDurationSeconds: durationSeconds,
      snapshotEndCursor: request.endCursor,
      conflicts: conflicts,
      unresolvedDeletesWarning: request.sourceMode == .pdsReconciliation,
      requestFingerprint: BackfillRequestFingerprint.canonicalRequest(request),
      validUntil: validUntil,
      methodology: methodology,
      confidence: "low",
      estimateKind: .modeled,
      uncertainty: BackfillEstimateUncertainty(
        lowerBound: max(0, estimatedCount / 2),
        upperBound: estimatedCount > Int.max / 2 ? Int.max : estimatedCount * 2)
    )
  }

  private static func modeledEstimate(for request: BackfillDryRunRequest) -> Int {
    switch request.sourceMode {
    case .jetstreamReplay:
      let delta = max(0, (request.endCursor ?? 0) - (request.startCursor ?? 0))
      return min(Int.max / 2, max(0, Int(Double(delta) / 1_000_000 * 250)))
    case .tapVerifiedResync, .pdsReconciliation:
      let (authors, authorOverflow) = request.authorDids.count.multipliedReportingOverflow(by: 100)
      let (estimate, collectionOverflow) = authors.multipliedReportingOverflow(
        by: max(1, request.collections.count)
      )
      return authorOverflow || collectionOverflow ? Int.max / 2 : estimate
    }
  }

  static func overlaps(_ job: BackfillJob, request: BackfillDryRunRequest) -> Bool {
    guard [.queued, .running, .paused].contains(job.status),
      job.sourceMode == request.sourceMode,
      !Set(job.collections).isDisjoint(with: request.collections)
    else { return false }

    if let gapId = request.gapId, job.gapId == gapId { return true }

    switch request.sourceMode {
    case .jetstreamReplay:
      guard let requestStart = request.startCursor, let requestEnd = request.endCursor,
        let jobStart = job.startCursor, let jobEnd = job.endCursor
      else { return false }
      return requestStart < jobEnd && jobStart < requestEnd
    case .tapVerifiedResync, .pdsReconciliation:
      return !Set(job.authorDids).isDisjoint(with: request.authorDids)
    }
  }
}

public enum BackfillRequestFingerprint {
  public static func make(
    canonicalRequest: String,
    estimatedCount: Int,
    validUntil: Date,
    environment: String,
    secret: String
  ) -> String {
    let expiry = Int(validUntil.timeIntervalSince1970)
    let signature = signatureHex(
      canonicalRequest: canonicalRequest, estimatedCount: estimatedCount, expiry: expiry,
      environment: environment, secret: secret)
    return "v1.\(expiry).\(signature)"
  }

  public static func validate(
    _ fingerprint: String,
    canonicalRequest: String,
    estimatedCount: Int,
    environment: String,
    secret: String,
    at: Date = Date()
  ) -> Bool {
    let parts = fingerprint.split(separator: ".", maxSplits: 2).map(String.init)
    guard parts.count == 3, parts[0] == "v1", let expiry = Int(parts[1]),
      expiry >= Int(at.timeIntervalSince1970)
    else { return false }
    let expected = signatureHex(
      canonicalRequest: canonicalRequest, estimatedCount: estimatedCount, expiry: expiry,
      environment: environment, secret: secret)
    return constantTimeEqual(parts[2], expected)
  }

  public static func validUntil(_ fingerprint: String) -> Date? {
    let parts = fingerprint.split(separator: ".", maxSplits: 2).map(String.init)
    guard parts.count == 3, parts[0] == "v1", let expiry = TimeInterval(parts[1]) else {
      return nil
    }
    return Date(timeIntervalSince1970: expiry)
  }

  public static func canonicalRequest(_ request: BackfillDryRunRequest) -> String {
    let startCursor = request.startCursor.map { String($0) } ?? ""
    let endCursor = request.endCursor.map { String($0) } ?? ""
    let collections = request.collections.sorted().joined(separator: ",")
    let authorDids = request.authorDids.sorted().joined(separator: ",")
    let components: [String] = [
      request.gapId ?? "",
      request.sourceMode.rawValue,
      startCursor,
      endCursor,
      collections,
      authorDids,
      String(request.batchSize),
      String(request.rateLimit),
      String(request.maxConcurrency),
    ]
    return components.joined(separator: "|")
  }

  private static func signatureHex(
    canonicalRequest: String,
    estimatedCount: Int,
    expiry: Int,
    environment: String,
    secret: String
  ) -> String {
    let purposeKey = SHA256.hash(data: Data("socialwire:operations:backfill:v1|\(secret)".utf8))
    let payload = "\(environment)|\(canonicalRequest)|\(estimatedCount)|\(expiry)"
    return HMAC<SHA256>.authenticationCode(
      for: Data(payload.utf8), using: SymmetricKey(data: Data(purposeKey))
    ).map { String(format: "%02x", $0) }.joined()
  }

  private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
    let left = Array(lhs.utf8)
    let right = Array(rhs.utf8)
    var difference = UInt8(truncatingIfNeeded: left.count ^ right.count)
    for index in 0..<max(left.count, right.count) {
      let a = index < left.count ? left[index] : 0
      let b = index < right.count ? right[index] : 0
      difference |= a ^ b
    }
    return difference == 0
  }
}
