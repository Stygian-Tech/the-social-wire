import Foundation
import Logging
import Testing

@testable import WireWorkerCore

struct WireMetadataClaimPacingTests {
  @Test("priority timeouts cool down, cap at a minute, and reset after progress")
  func priorityCooldown() async {
    let pacing = WireMetadataPriorityClaimPacing()
    var now = ContinuousClock.now
    for delay in [5, 10, 20, 40, 60, 60] {
      #expect(await pacing.begin(now: now))
      #expect(await pacing.begin(now: now) == false)
      await pacing.failed(now: now)
      #expect(await pacing.begin(now: now.advanced(by: .seconds(delay - 1))) == false)
      now = now.advanced(by: .seconds(delay))
    }
    #expect(await pacing.begin(now: now))
    await pacing.succeeded()
    #expect(await pacing.begin(now: now))
    await pacing.failed(now: now)
    #expect(await pacing.begin(now: now.advanced(by: .seconds(5))))
  }

  @Test("metadata runtime bounds repeated failures and resets after successful idle work")
  func runtimeBackoff() async throws {
    let probe = MetadataRuntimeProbe()
    await #expect(throws: CancellationError.self) {
      try await WireMetadataEnrichmentRuntime.run(
        logger: Logger(label: "metadata-backoff-test"), idleMilliseconds: 250,
        batch: { try await probe.batch() }, sleep: { try await probe.sleep($0) })
    }
    #expect(await probe.delays == [5, 10, 20, 40, 60, 60].map { .seconds($0) }
      + [.milliseconds(250), .seconds(5)])
  }
}

private actor MetadataRuntimeProbe {
  enum Failure: Error { case unavailable }
  var batches = 0
  var delays: [Duration] = []
  func batch() throws -> Int {
    batches += 1
    if batches == 7 { return 0 }
    throw Failure.unavailable
  }
  func sleep(_ duration: Duration) throws {
    delays.append(duration)
    if delays.count == 8 { throw CancellationError() }
  }
}
