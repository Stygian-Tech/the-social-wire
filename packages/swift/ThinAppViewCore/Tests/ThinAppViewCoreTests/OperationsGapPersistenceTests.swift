import Foundation
import Logging
import OperationsCore
import Testing

@Suite("Operations ingestion gap persistence")
struct OperationsGapPersistenceTests {
  @Test("confirmed ingestion gaps remain actionable in the active view")
  func confirmedGapRemainsActionable() async throws {
    let path = NSTemporaryDirectory() + "jetstream-gap-\(UUID().uuidString).sqlite"
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try SQLiteOperationsStore(
      path: path,
      environment: "test",
      logger: Logger(label: "jetstream-gap.test")
    )
    let gap = try await store.createGap(
      source: "jetstream",
      startCursor: 1_000,
      endCursor: 2_000,
      reason: "transport_disconnect",
      collections: ["site.standard.document"],
      detectedAt: Date()
    )

    _ = try await store.transitionGap(
      id: gap.id, to: .confirmed, expectedVersion: gap.version,
      operatorDid: "system:test", idempotencyKey: "confirm-\(gap.id)",
      requestId: nil, note: nil, at: Date()
    )

    let page = try await store.listGaps(view: .active, limit: 10, before: nil)
    #expect(page.items.first(where: { $0.id == gap.id })?.status == .confirmed)
    #expect(!page.items.contains(where: { $0.id == gap.id && $0.status == .resolved }))
  }

  @Test("verification-required gaps retain their exact cursor range in the active view")
  func verificationRequiredRangePersists() async throws {
    let path = NSTemporaryDirectory() + "jetstream-covered-\(UUID().uuidString).sqlite"
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try SQLiteOperationsStore(
      path: path,
      environment: "test",
      logger: Logger(label: "jetstream-covered.test")
    )
    let suspected = try await store.createGap(
      source: "jetstream",
      startCursor: 1_000,
      endCursor: 3_000,
      reason: "transport_disconnect",
      collections: [],
      detectedAt: Date()
    )
    let confirmed = try await store.transitionGap(
      id: suspected.id,
      to: .confirmed,
      expectedVersion: suspected.version,
      operatorDid: "system:test",
      idempotencyKey: "confirm-\(suspected.id)",
      requestId: nil,
      note: nil,
      at: Date()
    )
    let queued = try await store.transitionGap(
      id: confirmed.id,
      to: .backfillQueued,
      expectedVersion: confirmed.version,
      operatorDid: "system:test",
      idempotencyKey: "queue-\(confirmed.id)",
      requestId: nil,
      note: nil,
      at: Date()
    )
    let backfilling = try await store.transitionGap(
      id: queued.id,
      to: .backfilling,
      expectedVersion: queued.version,
      operatorDid: "system:test",
      idempotencyKey: "run-\(queued.id)",
      requestId: nil,
      note: nil,
      at: Date()
    )
    let verificationRequired = try await store.transitionGap(
      id: backfilling.id,
      to: .verificationRequired,
      expectedVersion: backfilling.version,
      operatorDid: "system:test",
      idempotencyKey: "verify-\(backfilling.id)",
      requestId: nil,
      note: nil,
      at: Date()
    )

    let active = try await store.listGaps(view: .active, limit: 10, before: nil)
    let persisted = try #require(active.items.first(where: { $0.id == verificationRequired.id }))
    #expect(persisted.status == .verificationRequired)
    #expect(persisted.startCursor == 1_000)
    #expect(persisted.endCursor == 3_000)
  }
}
