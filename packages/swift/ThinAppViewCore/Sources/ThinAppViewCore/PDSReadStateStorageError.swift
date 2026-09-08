public enum PDSReadStateStorageError: Error, Equatable {
  case revisionChanged
  case alreadyMigrated
  case legacyScopeUnavailable
  case parityMismatch
  case invalidCursor
  case staleGeneration
}
