public enum ReadStateError: Error, Equatable {
  case invalidRecord
  case invalidReference
  case incompleteGeneration
  case conflictingSequence
  case sizeLimit
}
