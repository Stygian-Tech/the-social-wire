import Foundation
import GatewayCore
import Testing

@testable import AppView

@Suite("Bootstrap stream completion evidence")
struct BootstrapStreamCompletionEvidenceTests {
  @Test("cached or unavailable entries prevent a live completion claim")
  func combinedEvidenceUsesLeastCurrentSource() {
    #expect(
      BootstrapStreamCompletionEvidence.combined(.liveProjection, .liveProjection)
        == .liveProjection
    )
    #expect(
      BootstrapStreamCompletionEvidence.combined(.liveProjection, .projectionCache)
        == .projectionCache
    )
    #expect(
      BootstrapStreamCompletionEvidence.combined(.projectionCache, .unavailable)
        == .unavailable
    )
    let newer = Date(timeIntervalSince1970: 1_800_000_100)
    let older = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(BootstrapStreamCompletionEvidence.oldest(nil, older) == older)
    #expect(BootstrapStreamCompletionEvidence.oldest(newer, older) == older)
  }

  @Test("failed live refresh is explicitly unavailable")
  func failedRefreshIsUnavailable() throws {
    let attemptedAt = Date(timeIntervalSince1970: 1_800_000_100)
    let event = BootstrapStreamCompletionEvidence.failed(
      attemptedAt: attemptedAt,
      cachedAt: nil
    )

    #expect(event.kind == .done)
    #expect(event.done?.source == .unavailable)
    #expect(event.done?.refreshedAt == attemptedAt)
    #expect(event.done?.source != .liveProjection)
  }

  @Test("failed cached emission preserves the original cache timestamp")
  func cachedTimestampIsPreserved() {
    let attemptedAt = Date(timeIntervalSince1970: 1_800_000_100)
    let cachedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let event = BootstrapStreamCompletionEvidence.failed(
      attemptedAt: attemptedAt,
      cachedAt: cachedAt
    )

    #expect(event.done?.source == .projectionCache)
    #expect(event.done?.refreshedAt == cachedAt)
  }
}
