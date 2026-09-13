import Foundation
import Testing

@testable import WireWorkerCore

@Suite("Metadata cleanup cursor")
struct WireMetadataPruneCursorTests {
  private let first = WireMetadataPruneCursor.Position(staleUntil: "2026-09-01 00:00:00.000001+00", canonicalKey: "a")
  private let second = WireMetadataPruneCursor.Position(staleUntil: "2026-09-01 00:00:00.000002+00", canonicalKey: "b")

  @Test("only committed batches advance; rollback and uncertain commit retry the same page")
  func commitAndRollback() async throws {
    let cursor = WireMetadataPruneCursor()
    _ = try await cursor.run(maximumBatches: 1) { position in
      #expect(position == nil)
      return .init(position: first)
    }
    await #expect(throws: CancellationError.self) {
      _ = try await cursor.run { position in
        #expect(position == first)
        throw CancellationError()
      }
    }
    _ = try await cursor.run(maximumBatches: 1) { position in
      #expect(position == first)
      return .init(position: second)
    }
    _ = try await cursor.run { position in
      #expect(position == second)
      return .init(position: nil)
    }
    _ = try await cursor.run { position in
      #expect(position == nil)
      return .init(position: nil)
    }
  }

  @Test("batch count and exhausted-tail boundary cap work without catch-up")
  func batchLimitAndWrap() async throws {
    let cursor = WireMetadataPruneCursor()
    let calls = Calls()
    let full = try await cursor.run(maximumBatches: 3) { _ in
      await calls.increment()
      return .init(position: first, examined: 500, deleted: 0)
    }
    #expect(await calls.count == 3)
    #expect(full?.examined == 1_500)
    #expect(full?.deleted == 0)
    #expect(full?.batches == 3)
    #expect(full?.wrapped == false)
    let tail = try await cursor.run(maximumBatches: 20) { _ in
      await calls.increment()
      return .init(position: nil, examined: 3, deleted: 2)
    }
    #expect(await calls.count == 4)
    #expect(tail?.examined == 3)
    #expect(tail?.deleted == 2)
    #expect(tail?.batches == 1)
    #expect(tail?.wrapped == true)
    _ = try await cursor.run(timeBudget: .zero) { _ in
      Issue.record("An exhausted budget must not begin another transaction")
      return .init(position: nil)
    }
  }

  @Test("a later batch failure retains progress from earlier committed batches")
  func partialPassFailure() async throws {
    let cursor = WireMetadataPruneCursor()
    await #expect(throws: CancellationError.self) {
      _ = try await cursor.run { position in
        if position == nil { return .init(position: first) }
        #expect(position == first)
        throw CancellationError()
      }
    }
    _ = try await cursor.run { position in
      #expect(position == first)
      return .init(position: nil)
    }
  }

  @Test("query time consumes the soft pass budget before another batch starts")
  func elapsedBudget() async throws {
    let cursor = WireMetadataPruneCursor()
    let calls = Calls()
    _ = try await cursor.run(timeBudget: .seconds(1)) { _ in
      await calls.increment()
      try await Task.sleep(for: .milliseconds(1_010))
      return .init(position: first)
    }
    #expect(await calls.count == 1)
  }

  @Test("overlapping passes coalesce and cancellation releases the cursor")
  func concurrencyAndCancellation() async throws {
    let cursor = WireMetadataPruneCursor()
    let started = Calls()
    let task = Task {
      _ = try await cursor.run { _ in
        await started.increment()
        try await Task.sleep(for: .seconds(60))
        return .init(position: first)
      }
    }
    while await started.count == 0 { await Task.yield() }
    _ = try await cursor.run { _ in
      Issue.record("Concurrent cleanup must not start another pass")
      return .init(position: nil)
    }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    _ = try await cursor.run { position in
      #expect(position == nil)
      return .init(position: nil)
    }
  }

  private actor Calls {
    var count = 0
    func increment() { count += 1 }
  }
}
