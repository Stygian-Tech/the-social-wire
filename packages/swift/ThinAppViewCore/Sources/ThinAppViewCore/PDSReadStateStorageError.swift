public enum PDSReadStateStorageError: Error, Equatable {
  case revisionChanged
  case alreadyMigrated
  case legacyScopeUnavailable
  case legacyScopeOverlap
  case parityMismatch
  case invalidCursor
  case projectionNotReady
  case staleGeneration
}
