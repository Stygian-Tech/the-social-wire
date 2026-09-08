import Foundation
import Logging

public enum OperationsTelemetrySignal: Sendable {
  case metric(OperationsMetricSample)
  case event(OperationsEvent)
  case span(TraceSpan)
}

public struct OperationsTelemetryBufferSnapshot: Sendable, Equatable {
  public let queueDepth: Int
  public let inFlightCount: Int
  public let capacity: Int
  public let droppedCount: Int
  public let consecutiveFailures: Int
  public let lastSuccessfulExportAt: Date?

  public init(
    queueDepth: Int,
    inFlightCount: Int,
    capacity: Int,
    droppedCount: Int,
    consecutiveFailures: Int,
    lastSuccessfulExportAt: Date?
  ) {
    self.queueDepth = queueDepth
    self.inFlightCount = inFlightCount
    self.capacity = capacity
    self.droppedCount = droppedCount
    self.consecutiveFailures = consecutiveFailures
    self.lastSuccessfulExportAt = lastSuccessfulExportAt
  }
}

public actor OperationsTelemetryBuffer {
  public typealias Signal = OperationsTelemetrySignal
  public typealias BatchExporter = @Sendable ([Signal]) async throws -> Void

  private let capacity: Int
  private let batchSize: Int
  private let maxRetryAttempts: Int
  private let batchDelay: Duration
  private let logger: Logger
  private let exporter: BatchExporter
  private var queue: [(signal: Signal, enqueuedAt: ContinuousClock.Instant)] = []
  private var inFlightCount = 0
  public private(set) var droppedCount = 0
  public private(set) var consecutiveFailures = 0
  public private(set) var lastSuccessfulExportAt: Date?

  public init(
    store: any OperationsStore,
    capacity: Int = 4_096,
    batchSize: Int = 100,
    maxRetryAttempts: Int = 5,
    batchDelay: Duration = .seconds(1),
    logger: Logger
  ) {
    self.capacity = max(1, capacity)
    self.batchSize = max(1, min(batchSize, capacity))
    self.maxRetryAttempts = max(1, maxRetryAttempts)
    self.batchDelay = max(.zero, batchDelay)
    self.logger = logger
    self.exporter = { signals in try await store.recordTelemetryBatch(signals) }
  }

  public init(
    capacity: Int,
    batchSize: Int = 100,
    maxRetryAttempts: Int = 5,
    batchDelay: Duration = .seconds(1),
    logger: Logger,
    exporter: @escaping BatchExporter
  ) {
    self.capacity = max(1, capacity)
    self.batchSize = max(1, min(batchSize, capacity))
    self.maxRetryAttempts = max(1, maxRetryAttempts)
    self.batchDelay = max(.zero, batchDelay)
    self.logger = logger
    self.exporter = exporter
  }

  @discardableResult
  public func enqueue(_ signal: Signal) -> Bool {
    enqueue(signal, at: ContinuousClock.now)
  }

  @discardableResult
  func enqueue(_ signal: Signal, at enqueuedAt: ContinuousClock.Instant) -> Bool {
    guard queue.count + inFlightCount < capacity else {
      droppedCount += 1
      return false
    }
    queue.append((signal, enqueuedAt))
    return true
  }

  public func runForever() async {
    while !Task.isCancelled {
      let exported = await flushIfReady(at: ContinuousClock.now)
      if exported == 0 {
        // Polling also wakes a newly full batch promptly while a partial batch accumulates.
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
  }

  @discardableResult
  func flushIfReady(at now: ContinuousClock.Instant) async -> Int {
    guard let oldest = queue.first else { return 0 }
    guard queue.count >= batchSize || oldest.enqueuedAt.duration(to: now) >= batchDelay else {
      return 0
    }
    return await flushOnce()
  }

  @discardableResult
  public func flushOnce() async -> Int {
    // Actor methods can reenter while the exporter or a retry is suspended. Keep the
    // original batch counted against capacity and preserve FIFO across every retry.
    guard inFlightCount == 0, !queue.isEmpty else { return 0 }
    let count = min(batchSize, queue.count)
    let batch = queue.prefix(count).map(\.signal)
    queue.removeFirst(count)
    inFlightCount = batch.count
    defer { inFlightCount = 0 }

    for attempt in 0..<maxRetryAttempts {
      do {
        try await exporter(batch)
        consecutiveFailures = 0
        lastSuccessfulExportAt = Date()
        return batch.count
      } catch {
        consecutiveFailures += 1
        guard attempt + 1 < maxRetryAttempts else {
          droppedCount += batch.count
          logger.error(
            "Telemetry export exhausted bounded retries",
            metadata: [
              "error_type": .string(OperationsRedactor.errorCategory(error)),
              "batch_size": .string(String(batch.count)),
            ])
          return 0
        }
        let baseMilliseconds = min(5_000, 100 * (1 << min(attempt, 5)))
        let jitterMilliseconds = Int.random(in: 0...max(1, baseMilliseconds / 4))
        try? await Task.sleep(for: .milliseconds(baseMilliseconds + jitterMilliseconds))
      }
    }
    return 0
  }

  public func pendingCount() -> Int { queue.count }

  public func snapshot() -> OperationsTelemetryBufferSnapshot {
    OperationsTelemetryBufferSnapshot(
      queueDepth: queue.count,
      inFlightCount: inFlightCount,
      capacity: capacity,
      droppedCount: droppedCount,
      consecutiveFailures: consecutiveFailures,
      lastSuccessfulExportAt: lastSuccessfulExportAt)
  }
}
