import Logging

actor WirePublicationCacheTelemetry {
  enum Outcome { case hit, miss, unavailable }
  private var hits = 0
  private var misses = 0
  private var unavailable = 0

  func record(_ outcome: Outcome) {
    switch outcome {
    case .hit: hits += 1
    case .miss: misses += 1
    case .unavailable: unavailable += 1
    }
  }

  func emit(logger: Logger) {
    guard hits + misses + unavailable > 0 else { return }
    logger.info("Wire publication cache observations", metadata: [
      "cache_hits": .stringConvertible(hits),
      "cache_misses": .stringConvertible(misses),
      "cache_unavailable": .stringConvertible(unavailable),
      "observation_window_seconds": "60",
    ])
    hits = 0
    misses = 0
    unavailable = 0
  }
}
