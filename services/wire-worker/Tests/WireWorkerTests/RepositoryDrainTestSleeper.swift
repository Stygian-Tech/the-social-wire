import Foundation

@testable import WireWorkerCore

actor RepositoryDrainTestSleeper: WireInboxDrainSleeping {
  private let ticks = AsyncStream<Void>.makeStream()
  private let changes = AsyncStream<Void>.makeStream()
  private var pending = 0
  private(set) var maximumPending = 0

  func sleep(milliseconds: Int) async throws {
    pending += 1
    maximumPending = max(maximumPending, pending)
    changes.continuation.yield()
    var iterator = ticks.stream.makeAsyncIterator()
    _ = await iterator.next()
    pending -= 1
    try Task.checkCancellation()
  }

  func waitUntilSleeping() async throws {
    var iterator = changes.stream.makeAsyncIterator()
    while pending == 0 {
      try Task.checkCancellation()
      guard await iterator.next() != nil else { throw CancellationError() }
    }
  }

  func tick() { ticks.continuation.yield() }
}
