import Logging
import Testing

@testable import WireWorkerCore

@Suite("Wire worker lifetime", .timeLimit(.minutes(1)))
struct WireWorkerLifetimeTests {
  @Test("lease cancellation closes the transport before joining a blocked child")
  func cancellationClosesTransport() async throws {
    let gate = TransportShutdownGate()
    let task = Task {
      try await WireWorkerLifetime.run(
        logger: Logger(label: "wire-lifetime.tests"), shutdown: { await gate.close() }
      ) { group in
        group.addTask { await gate.waitForTransport() }
      }
    }
    var started = gate.started.makeAsyncIterator()
    _ = await started.next()
    task.cancel()
    _ = await task.result
    #expect(await gate.closeCount == 1)
    #expect(await gate.childFinished)
  }

  @Test("a failed sibling closes the transport and preserves the original error")
  func failureClosesTransport() async throws {
    let gate = TransportShutdownGate()
    await #expect(throws: LifetimeFailure.expected) {
      try await WireWorkerLifetime.run(
        logger: Logger(label: "wire-lifetime.tests"), shutdown: { await gate.close() }
      ) { group in
        group.addTask { await gate.waitForTransport() }
        group.addTask {
          var started = gate.started.makeAsyncIterator()
          _ = await started.next()
          throw LifetimeFailure.expected
        }
      }
    }
    #expect(await gate.closeCount == 1)
    #expect(await gate.childFinished)
  }
}

private enum LifetimeFailure: Error { case expected }

/// Models a dependency awaiting a socket/future that completes only when its owner
/// closes the transport. Parent cancellation alone intentionally cannot unblock it.
private actor TransportShutdownGate {
  nonisolated let started: AsyncStream<Void>
  private let start: AsyncStream<Void>.Continuation
  private var waiting: CheckedContinuation<Void, Never>?
  private(set) var closeCount = 0
  private(set) var childFinished = false

  init() { (started, start) = AsyncStream.makeStream(of: Void.self) }

  func waitForTransport() async {
    if closeCount == 0 {
      await withCheckedContinuation { continuation in
        waiting = continuation
        start.yield(())
      }
    }
    childFinished = true
  }

  func close() {
    closeCount += 1
    waiting?.resume()
    waiting = nil
  }
}
