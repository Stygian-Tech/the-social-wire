public protocol SportsSelectionStoring: Actor {
  func applySportsSelection(_ mutation: SportsSelectionMutation) async throws
}
