import Foundation
import Logging
import Testing

@testable import OperationsCore

@Suite("Gap investigation")
struct GapInvestigationTests {
  @Test("correlates a commit failure followed by disconnect as a high-confidence trigger")
  func correlatesCommitFailureAndDisconnect() {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let gap = makeGap(at: now)
    let failure = OperationsEvent(
      id: "failure",
      service: "appview-worker",
      environment: "dev",
      instanceId: "worker-1",
      name: "commit.failed",
      occurredAt: now.addingTimeInterval(-2),
      attributes: ["error_type": "database_timeout", "collection": "site.standard.entry"]
    )
    let disconnect = OperationsEvent(
      id: "disconnect",
      service: "appview-worker",
      environment: "dev",
      instanceId: "worker-1",
      name: "jetstream.disconnected",
      occurredAt: now,
      attributes: ["error_type": "database_timeout"]
    )

    let investigation = GapInvestigationBuilder.build(
      gap: gap,
      events: [failure, disconnect],
      spans: [],
      services: [],
      alerts: []
    )

    #expect(investigation.assessment.confidence == .high)
    #expect(investigation.assessment.title == "Indexing failure interrupted commit advancement")
    #expect(investigation.assessment.evidenceIds == ["event-failure", "event-disconnect"])
  }

  @Test("reports insufficient evidence instead of inventing a cause")
  func reportsInsufficientEvidence() {
    let investigation = GapInvestigationBuilder.build(
      gap: makeGap(at: Date()),
      events: [],
      spans: [],
      services: [],
      alerts: []
    )

    #expect(investigation.assessment.confidence == .insufficient)
    #expect(investigation.assessment.evidenceIds == ["gap-detected"])
  }

  @Test("event queries are bounded to the investigation window")
  func eventWindowQuery() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("operations-investigation-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try SQLiteOperationsStore(
      path: url.path, environment: "dev", logger: Logger(label: "investigation.test"))
    let now = Date()
    try await store.recordEvent(
      OperationsEvent(
        id: "inside",
        service: "appview-worker",
        environment: "dev",
        instanceId: "worker-1",
        name: "jetstream.disconnected",
        occurredAt: now
      )
    )
    try await store.recordEvent(
      OperationsEvent(
        id: "noise",
        service: "appview-worker",
        environment: "dev",
        instanceId: "worker-1",
        name: "commit.committed",
        occurredAt: now
      )
    )
    try await store.recordEvent(
      OperationsEvent(
        id: "outside",
        service: "appview-worker",
        environment: "dev",
        instanceId: "worker-1",
        name: "jetstream.connected",
        occurredAt: now.addingTimeInterval(-3_600)
      )
    )

    let events = try await store.listGapInvestigationEvents(
      startAt: now.addingTimeInterval(-60),
      endAt: now.addingTimeInterval(60),
      limit: 10
    )
    #expect(events.map(\.id) == ["inside"])
  }

  private func makeGap(at date: Date) -> IngestionGap {
    let cursor = Int64(date.timeIntervalSince1970 * 1_000_000)
    return IngestionGap(
      id: "gap-1",
      environment: "local",
      source: "jetstream",
      startCursor: cursor - 1_000_000,
      endCursor: cursor,
      startTime: nil,
      endTime: nil,
      reason: "unknown",
      status: .confirmed,
      collections: [],
      detectedAt: date,
      updatedAt: date,
      backfillJobId: nil,
      discoveredCount: 0,
      processedCount: 0,
      failedCount: 0,
      reconciledCount: 0,
      version: 0
    )
  }
}
