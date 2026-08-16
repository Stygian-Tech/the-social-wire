import Foundation

public struct BoundedQueueObservation: Sendable, Equatable {
  public let depth: Int
  public let capacity: Int
  public let dropped: Int64

  public init(depth: Int, capacity: Int, dropped: Int64) {
    self.depth = max(0, depth)
    self.capacity = max(1, capacity)
    self.dropped = max(0, dropped)
  }
}

enum BoundedMessageEnqueueResult: Sendable, Equatable {
  case accepted
  case saturated
  case stopped
}

/// A bounded FIFO for callback-based transports. Saturation is reported synchronously so callers reconnect.
final class BoundedSequentialMessagePump: @unchecked Sendable {
  private let lock = NSLock()
  private let capacity: Int
  private let handleMessage: @Sendable (String) async throws -> Void
  private let onFailure: @Sendable (Error) -> Void
  private let onObservation: @Sendable (BoundedQueueObservation) -> Void
  private var tail: Task<Void, Never>?
  private var pending = 0
  private var accepting = true
  private var failed = false
  private var dropped: Int64 = 0

  init(
    capacity: Int,
    handleMessage: @Sendable @escaping (String) async throws -> Void,
    onFailure: @Sendable @escaping (Error) -> Void,
    onObservation: @Sendable @escaping (BoundedQueueObservation) -> Void = { _ in }
  ) {
    self.capacity = max(1, capacity)
    self.handleMessage = handleMessage
    self.onFailure = onFailure
    self.onObservation = onObservation
  }

  func enqueue(_ message: String) -> BoundedMessageEnqueueResult {
    lock.lock()
    guard accepting, !failed else {
      dropped += 1
      let observation = observationLocked()
      lock.unlock()
      onObservation(observation)
      return .stopped
    }
    guard pending < capacity else {
      failed = true
      dropped += 1
      let observation = observationLocked()
      lock.unlock()
      onObservation(observation)
      return .saturated
    }
    pending += 1
    let observation = observationLocked()
    let previous = tail
    tail = Task { [weak self] in
      _ = await previous?.result
      guard let self else { return }
      guard !isFailed else {
        completedOne()
        return
      }
      do {
        try await handleMessage(message)
      } catch {
        markFailed()
        onFailure(error)
      }
      completedOne()
    }
    lock.unlock()
    onObservation(observation)
    return .accepted
  }

  /// Prevents new messages from entering the pump while allowing every accepted message to drain.
  /// Transports must call this before assessing a graceful close so an in-flight commit does not
  /// look like a durable ingestion gap.
  func stopAccepting() {
    lock.lock()
    accepting = false
    lock.unlock()
  }

  /// Waits for the messages currently accepted by the pump to finish processing.
  /// Callers should stop enqueueing before awaiting this method.
  func waitUntilIdle() async {
    _ = await currentTail()?.result
  }

  private func currentTail() -> Task<Void, Never>? {
    lock.lock()
    defer { lock.unlock() }
    return tail
  }

  private func completedOne() {
    lock.lock()
    pending = max(0, pending - 1)
    let observation = observationLocked()
    lock.unlock()
    onObservation(observation)
  }

  private var isFailed: Bool {
    lock.lock()
    defer { lock.unlock() }
    return failed
  }

  private func markFailed() {
    lock.lock()
    accepting = false
    failed = true
    lock.unlock()
  }

  private func observationLocked() -> BoundedQueueObservation {
    BoundedQueueObservation(depth: pending, capacity: capacity, dropped: dropped)
  }
}
