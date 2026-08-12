public enum PDSResolutionCacheLookup: Sendable, Equatable {
  case fresh(String?)
  case stale(String?)
  case miss
}
