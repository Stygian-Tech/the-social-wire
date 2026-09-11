import Foundation
import Logging
import Testing

@testable import OperationsCore

@Suite("Operations telemetry buffer")
struct OperationsTelemetryBufferTests {
  @Test("orders metric batches by their durable rollup keys")
  func metricBatchLockOrderIsDeterministic() {
    let recordedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let first = OperationsTelemetrySignal.metric(
      .init(
        name: "socialwire.worker.events_total",
        value: 1,
        dimensions: ["collection": "site.standard.entry", "service": "worker"],
        recordedAt: recordedAt))
    let second = OperationsTelemetrySignal.metric(
      .init(
        name: "socialwire.gateway.requests_total",
        value: 1,
        dimensions: ["service": "gateway", "status_class": "2xx"],
        recordedAt: recordedAt))

    let forward = OperationsTelemetrySignalOrder.sorted([first, second])
      .compactMap(Self.metricIdentity)
    let reverse = OperationsTelemetrySignalOrder.sorted([second, first])
      .compactMap(Self.metricIdentity)

    #expect(forward == reverse)
    #expect(forward.count == 2)
  }

  @Test("drops sampled telemetry when the bounded queue is full")
  func overflowDropsWithoutBlocking() async throws {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("operations-buffer-\(UUID().uuidString).sqlite").path
    let logger = Logger(label: "operations-buffer-tests")
    let store = try SQLiteOperationsStore(path: path, environment: "dev", logger: logger)
    let buffer = OperationsTelemetryBuffer(store: store, capacity: 1, logger: logger)

    let first = await buffer.enqueue(
      .metric(.init(name: "socialwire.test", value: 1, dimensions: [:])))
    let second = await buffer.enqueue(
      .metric(.init(name: "socialwire.test", value: 2, dimensions: [:])))

    #expect(first)
    #expect(!second)
    #expect(await buffer.pendingCount() == 1)
    #expect(await buffer.droppedCount == 1)
  }

  @Test("an idle exporter stops promptly when cancelled")
  func idleExporterCancellation() async {
    let logger = Logger(label: "operations-buffer-cancellation-tests")
    let buffer = OperationsTelemetryBuffer(
      capacity: 1, logger: logger,
      exporter: { _ in })
    let task = Task { await buffer.runForever() }

    try? await Task.sleep(for: .milliseconds(10))
    let clock = ContinuousClock()
    let started = clock.now
    task.cancel()
    await task.value

    #expect(started.duration(to: clock.now) < .seconds(1))
  }

  @Test("partial batches coalesce for one second without changing samples")
  func partialBatchDelay() async {
    let recorder = ExportRecorder()
    let buffer = OperationsTelemetryBuffer(
      capacity: 100, logger: Logger(label: "operations-buffer-delay-tests"),
      exporter: { try await recorder.record($0) })
    let start = ContinuousClock.now
    for value in 0..<10 {
      #expect(await buffer.enqueue(Self.metric(value), at: start.advanced(by: .milliseconds(value * 100))))
      #expect(await buffer.flushIfReady(at: start.advanced(by: .milliseconds(value * 100))) == 0)
    }
    #expect(await buffer.flushIfReady(at: start.advanced(by: .milliseconds(999))) == 0)
    #expect(await buffer.flushIfReady(at: start.advanced(by: .seconds(1))) == 10)
    #expect(await recorder.values == [Array(0..<10).map(Double.init)])
    #expect(await buffer.droppedCount == 0)
  }

  @Test("full batches export before the delay and partial tails retain their original age")
  func fullBatchAndAgedTail() async {
    let recorder = ExportRecorder()
    let buffer = OperationsTelemetryBuffer(
      capacity: 10, batchSize: 2, batchDelay: .seconds(1),
      logger: Logger(label: "operations-buffer-full-tests"),
      exporter: { try await recorder.record($0) })
    let start = ContinuousClock.now
    for value in 0..<3 {
      #expect(await buffer.enqueue(Self.metric(value), at: start))
    }
    #expect(await buffer.flushIfReady(at: start) == 2)
    #expect(await buffer.flushIfReady(at: start.advanced(by: .milliseconds(999))) == 0)
    #expect(await buffer.flushIfReady(at: start.advanced(by: .seconds(1))) == 1)
    #expect(await recorder.values == [[0, 1], [2]])
  }

  @Test("manual flush bypasses the configurable batching delay")
  func manualFlushIsImmediate() async {
    let recorder = ExportRecorder()
    let buffer = OperationsTelemetryBuffer(
      capacity: 10, batchDelay: .seconds(30),
      logger: Logger(label: "operations-buffer-manual-tests"),
      exporter: { try await recorder.record($0) })
    #expect(await buffer.enqueue(Self.metric(42)))
    #expect(await buffer.flushOnce() == 1)
    #expect(await recorder.values == [[42]])
  }

  @Test("suspended exports cannot overlap or release their reserved capacity")
  func concurrentFlushPreservesCapacityAndOrder() async {
    let recorder = ExportRecorder(holdFirst: true)
    let buffer = OperationsTelemetryBuffer(
      capacity: 3, batchSize: 1,
      logger: Logger(label: "operations-buffer-concurrent-tests"),
      exporter: { try await recorder.record($0) })
    #expect(await buffer.enqueue(Self.metric(1)))
    let first = Task { await buffer.flushOnce() }
    await recorder.waitForFirstExport()

    #expect(await buffer.enqueue(Self.metric(2)))
    #expect(await buffer.flushOnce() == 0)
    #expect(await buffer.enqueue(Self.metric(3)))
    #expect(!(await buffer.enqueue(Self.metric(4))))
    let suspended = await buffer.snapshot()
    #expect(suspended.queueDepth == 2)
    #expect(suspended.inFlightCount == 1)
    #expect(suspended.droppedCount == 1)
    #expect(suspended.lastDropAt != nil)
    #expect(suspended.lastDropRecoveredAt == nil)

    await recorder.releaseFirstExport()
    #expect(await first.value == 1)
    #expect(await buffer.snapshot().lastDropRecoveredAt == nil)
    #expect(await buffer.flushOnce() == 1)
    #expect(await buffer.flushOnce() == 1)
    #expect(await recorder.values == [[1], [2], [3]])
    #expect(await buffer.snapshot().inFlightCount == 0)
  }

  @Test("a failed export retries the same batch before exporting its queued successor")
  func retryPreservesBatchAndQueue() async {
    let recorder = ExportRecorder(holdFirst: true, failFirst: true)
    let buffer = OperationsTelemetryBuffer(
      capacity: 3, batchSize: 2, maxRetryAttempts: 2,
      logger: Logger(label: "operations-buffer-retry-tests"),
      exporter: { try await recorder.record($0) })
    #expect(await buffer.enqueue(Self.metric(1)))
    #expect(await buffer.enqueue(Self.metric(2)))
    let first = Task { await buffer.flushOnce() }
    await recorder.waitForFirstExport()
    #expect(await buffer.enqueue(Self.metric(3)))
    #expect(await buffer.flushOnce() == 0)
    await recorder.releaseFirstExport()
    #expect(await first.value == 2)
    #expect(await buffer.flushOnce() == 1)
    #expect(await recorder.values == [[1, 2], [1, 2], [3]])
    let snapshot = await buffer.snapshot()
    #expect(snapshot.droppedCount == 0)
    #expect(snapshot.consecutiveFailures == 0)
    #expect(snapshot.lastSuccessfulExportAt != nil)
  }

  @Test("cancelling while a partial batch accumulates preserves queued samples for explicit flush")
  func partialBatchCancellation() async {
    let recorder = ExportRecorder()
    let buffer = OperationsTelemetryBuffer(
      capacity: 10, batchDelay: .seconds(60),
      logger: Logger(label: "operations-buffer-partial-cancellation-tests"),
      exporter: { try await recorder.record($0) })
    #expect(await buffer.enqueue(Self.metric(7)))
    let task = Task { await buffer.runForever() }
    task.cancel()
    await task.value
    #expect(await recorder.values.isEmpty)
    #expect(await buffer.pendingCount() == 1)
    #expect(await buffer.flushOnce() == 1)
    #expect(await recorder.values == [[7]])
  }

  @Test("a cancelled exporter is not replayed and releases reserved capacity")
  func cancelledExportDoesNotRetry() async {
    let recorder = CancelledExportRecorder()
    let buffer = OperationsTelemetryBuffer(
      capacity: 2, batchSize: 1, maxRetryAttempts: 5,
      logger: Logger(label: "operations-buffer-cancelled-export-tests"),
      exporter: { _ in try await recorder.export() })
    #expect(await buffer.enqueue(Self.metric(1)))
    #expect(await buffer.enqueue(Self.metric(2)))
    #expect(await buffer.flushOnce() == 0)
    #expect(await recorder.attempts == 1)
    let snapshot = await buffer.snapshot()
    #expect(snapshot.queueDepth == 1 && snapshot.inFlightCount == 0)
    #expect(snapshot.droppedCount == 1 && snapshot.consecutiveFailures == 1)
    #expect(snapshot.lastDropAt != nil && snapshot.lastDropRecoveredAt == nil)
  }

  private actor CancelledExportRecorder {
    private(set) var attempts = 0

    func export() throws {
      attempts += 1
      throw CancellationError()
    }
  }

  @Test("loss recovers only after a successful drain and preserves lifetime evidence")
  func lossRecoveryAfterDrain() async {
    let clock = TestClock()
    let recorder = ExportRecorder(failFirst: true)
    let buffer = OperationsTelemetryBuffer(
      capacity: 2, batchSize: 1, maxRetryAttempts: 1,
      logger: Logger(label: "operations-buffer-recovery-tests"), now: { clock.next() },
      exporter: { try await recorder.record($0) })
    #expect(await buffer.enqueue(Self.metric(1)))
    #expect(await buffer.flushOnce() == 0)
    let failed = await buffer.snapshot()
    #expect(failed.droppedCount == 1)
    #expect(failed.lastDropAt != nil)
    #expect(failed.lastDropRecoveredAt == nil)
    #expect(failed.consecutiveFailures == 1)

    #expect(await buffer.enqueue(Self.metric(2)))
    #expect(await buffer.enqueue(Self.metric(3)))
    #expect(await buffer.flushOnce() == 1)
    let partial = await buffer.snapshot()
    #expect(partial.consecutiveFailures == 0)
    #expect(partial.lastDropRecoveredAt == nil)
    #expect(partial.queueDepth == 1)
    #expect(await buffer.flushOnce() == 1)
    let recovered = await buffer.snapshot()
    #expect(recovered.droppedCount == 1)
    #expect(recovered.lastDropAt == failed.lastDropAt)
    #expect(recovered.lastDropRecoveredAt == recovered.lastSuccessfulExportAt)
    #expect(recovered.lastDropRecoveredAt! > failed.lastDropAt!)
    #expect(recovered.inFlightCount == 0)

    #expect(await buffer.enqueue(Self.metric(4)))
    #expect(await buffer.snapshot().lastDropRecoveredAt == recovered.lastDropRecoveredAt)
    #expect(await buffer.enqueue(Self.metric(5)))
    #expect(!(await buffer.enqueue(Self.metric(6))))
    let recurrence = await buffer.snapshot()
    #expect(recurrence.droppedCount == 2)
    #expect(recurrence.lastDropAt! > recovered.lastDropRecoveredAt!)
    #expect(recurrence.lastDropRecoveredAt == nil)
  }

  private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Date(timeIntervalSince1970: 1_800_000_000)
    func next() -> Date {
      lock.lock()
      defer { lock.unlock() }
      time = time.addingTimeInterval(1)
      return time
    }
  }

  private static func metric(_ value: Int) -> OperationsTelemetrySignal {
    .metric(.init(name: "socialwire.test", value: Double(value), dimensions: [:]))
  }

  private actor ExportRecorder {
    private enum ExportFailure: Error { case unavailable }
    private let holdFirst: Bool
    private let failFirst: Bool
    private var firstExportWaiter: CheckedContinuation<Void, Never>?
    private var releaseFirst: CheckedContinuation<Void, Never>?
    private(set) var values: [[Double]] = []

    init(holdFirst: Bool = false, failFirst: Bool = false) {
      self.holdFirst = holdFirst
      self.failFirst = failFirst
    }

    func record(_ signals: [OperationsTelemetrySignal]) async throws {
      values.append(signals.compactMap {
        guard case .metric(let sample) = $0 else { return nil }
        return sample.value
      })
      if holdFirst && values.count == 1 {
        await withCheckedContinuation { continuation in
          releaseFirst = continuation
          firstExportWaiter?.resume()
          firstExportWaiter = nil
        }
      }
      if failFirst && values.count == 1 { throw ExportFailure.unavailable }
    }

    func waitForFirstExport() async {
      guard values.isEmpty else { return }
      await withCheckedContinuation { firstExportWaiter = $0 }
    }

    func releaseFirstExport() {
      releaseFirst?.resume()
      releaseFirst = nil
    }
  }

  private static func metricIdentity(_ signal: OperationsTelemetrySignal) -> String? {
    guard case .metric(let sample) = signal else { return nil }
    return [
      sample.name,
      sample.dimensions.sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value)" }
        .joined(separator: "&"),
    ].joined(separator: "|")
  }
}
