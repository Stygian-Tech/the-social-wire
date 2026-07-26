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

/// A bounded FIFO for callback-based transports. Saturation is reported synchronously so callers reconnect.
final class BoundedSequentialMessagePump: @unchecked Sendable {
  private let lock = NSLock()
  private let capacity: Int
  private let handleMessage: @Sendable (String) async throws -> Void
  private let onFailure: @Sendable (Error) -> Void
  private let onObservation: @Sendable (BoundedQueueObservation) -> Void
  private var tail: Task<Void, Never>?
  private var pending = 0
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

  func enqueue(_ message: String) -> Bool {
    lock.lock()
    guard pending < capacity, !failed else {
      dropped += 1
      let observation = observationLocked()
      lock.unlock()
      onObservation(observation)
      return false
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
    return true
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
    failed = true
    lock.unlock()
  }

  private func observationLocked() -> BoundedQueueObservation {
    BoundedQueueObservation(depth: pending, capacity: capacity, dropped: dropped)
  }
}
