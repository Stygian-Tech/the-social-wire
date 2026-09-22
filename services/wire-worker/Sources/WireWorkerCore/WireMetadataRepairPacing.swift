/// Historical repair yields after empty sweeps or failures. New items still seed
/// metadata atomically on write, independently of this recovery sweep.
struct WireMetadataRepairPacing {
  private let baselineMilliseconds: Int
  private var idleMilliseconds: Int
  private var failureMilliseconds: Int?
  private var observedSweepBoundary = false
  private var repairedInSweep = false

  init(intervalMilliseconds: Int) {
    baselineMilliseconds = max(250, min(60_000, intervalMilliseconds))
    idleMilliseconds = baselineMilliseconds
  }

  var delayMilliseconds: Int { failureMilliseconds ?? idleMilliseconds }

  mutating func succeeded(_ progress: WireMetadataRepairProgress) {
    failureMilliseconds = nil
    if progress.repaired > 0 {
      repairedInSweep = true
      idleMilliseconds = baselineMilliseconds
    }
    guard progress.wrapped else { return }
    // The persisted cursor can start midway through a sweep. Observe a complete
    // sweep before slowing recovery; a partial empty tail is not evidence of idleness.
    if observedSweepBoundary && !repairedInSweep {
      idleMilliseconds = min(60_000, idleMilliseconds * 2)
    }
    observedSweepBoundary = true
    repairedInSweep = false
  }

  mutating func failed() {
    failureMilliseconds = min(60_000, delayMilliseconds * 2)
  }
}
