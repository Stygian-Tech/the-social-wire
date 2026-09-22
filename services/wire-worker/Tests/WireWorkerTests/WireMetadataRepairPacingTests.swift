import Testing

@testable import WireWorkerCore

struct WireMetadataRepairPacingTests {
  @Test("empty pages and an initial partial sweep preserve recovery cadence")
  func partialSweep() {
    var pacing = WireMetadataRepairPacing(intervalMilliseconds: 1_000)
    for _ in 0..<10 {
      pacing.succeeded(.init(scanned: 1_000, repaired: 0, wrapped: false))
    }
    #expect(pacing.delayMilliseconds == 1_000)
    pacing.succeeded(.init(scanned: 20, repaired: 0, wrapped: true))
    #expect(pacing.delayMilliseconds == 1_000)
    pacing.succeeded(.init(scanned: 0, repaired: 0, wrapped: true))
    #expect(pacing.delayMilliseconds == 2_000)
    pacing.succeeded(.init(scanned: 1_000, repaired: 0, wrapped: false))
    #expect(pacing.delayMilliseconds == 2_000)
  }

  @Test("useful repair immediately resets pacing and prevents idle sweep backoff")
  func usefulRepair() {
    var pacing = WireMetadataRepairPacing(intervalMilliseconds: 1_000)
    for _ in 0..<4 {
      pacing.succeeded(.init(scanned: 0, repaired: 0, wrapped: true))
    }
    pacing.failed()
    pacing.succeeded(.init(scanned: 1_000, repaired: 1, wrapped: false))
    #expect(pacing.delayMilliseconds == 1_000)
    pacing.succeeded(.init(scanned: 10, repaired: 0, wrapped: true))
    #expect(pacing.delayMilliseconds == 1_000)
    pacing.succeeded(.init(scanned: 10, repaired: 0, wrapped: true))
    #expect(pacing.delayMilliseconds == 2_000)
  }

  @Test("repeated failures yield and success restores the prior idle cadence")
  func failureRecovery() {
    var pacing = WireMetadataRepairPacing(intervalMilliseconds: 1_000)
    pacing.failed()
    #expect(pacing.delayMilliseconds == 2_000)
    pacing.failed()
    #expect(pacing.delayMilliseconds == 4_000)
    pacing.succeeded(.init(scanned: 1_000, repaired: 0, wrapped: false))
    #expect(pacing.delayMilliseconds == 1_000)
    for _ in 0..<3 {
      pacing.succeeded(.init(scanned: 0, repaired: 0, wrapped: true))
    }
    pacing.failed()
    #expect(pacing.delayMilliseconds == 8_000)
    pacing.succeeded(.init(scanned: 1_000, repaired: 0, wrapped: false))
    #expect(pacing.delayMilliseconds == 4_000)
  }

  @Test("idle and failure delays stay inside configured pacing bounds")
  func bounds() {
    var pacing = WireMetadataRepairPacing(intervalMilliseconds: -1)
    #expect(pacing.delayMilliseconds == 250)
    for _ in 0..<100 {
      pacing.succeeded(.init(scanned: 0, repaired: 0, wrapped: true))
    }
    #expect(pacing.delayMilliseconds == 60_000)
    for _ in 0..<100 { pacing.failed() }
    #expect(pacing.delayMilliseconds == 60_000)
    pacing.succeeded(.init(scanned: 1, repaired: 1, wrapped: true))
    #expect(pacing.delayMilliseconds == 250)
    #expect(WireMetadataRepairPacing(intervalMilliseconds: Int.max).delayMilliseconds == 60_000)
  }
}
