import Foundation
import GatewayCore
import ThinAppViewCore

struct BootstrapEntriesPageSelection: Sendable {
  let page: AppViewEntryListResponse
  let source: AppViewBootstrapEvidenceSource
  let cachedAt: Date?
  let expiresAt: Date?

  static func load(
    enrollment: BootstrapEnrollment,
    livePage: () async throws -> AppViewEntryListResponse?,
    cachedPage: () async throws -> AppViewProjectionCacheEntry<AppViewEntryListResponse>?
  ) async throws -> Self {
    try Task.checkCancellation()
    // A completed backfill can improve page one; an unfinished one cannot delay it.
    if await enrollment.isFinished, let page = try await livePage() {
      try Task.checkCancellation()
      return Self(page: page, source: .liveProjection, cachedAt: nil, expiresAt: nil)
    }
    if let cached = try await cachedPage() {
      try Task.checkCancellation()
      return Self(
        page: cached.value,
        source: AppViewBootstrapEvidenceSource(rawValue: cached.source.rawValue) ?? .unavailable,
        cachedAt: cached.cachedAt,
        expiresAt: cached.expiresAt
      )
    }
    try Task.checkCancellation()
    return Self(
      page: AppViewEntryListResponse(entries: [], cursor: nil),
      source: .unavailable,
      cachedAt: nil,
      expiresAt: nil
    )
  }
}
