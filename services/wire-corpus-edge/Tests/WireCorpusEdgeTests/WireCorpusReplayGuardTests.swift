import Foundation
import Testing
@testable import WireCorpusEdge

@Suite("The Wire Corpus Edge replay guard")
struct WireCorpusReplayGuardTests {
  @Test("rejects replay and fails closed at capacity until entries expire")
  func replayAndCapacity() async {
    let guardStore = WireCorpusReplayGuard(capacity: 1)
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    #expect(await guardStore.consume(nonce: "one", now: now))
    #expect(!(await guardStore.consume(nonce: "one", now: now)))
    #expect(!(await guardStore.consume(nonce: "two", now: now)))
    #expect(await guardStore.consume(nonce: "two", now: now.addingTimeInterval(61)))
  }
}
