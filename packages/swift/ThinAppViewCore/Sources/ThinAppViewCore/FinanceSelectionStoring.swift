public protocol FinanceSelectionStoring: Actor {
  func applyFinanceSelection(_ mutation: FinanceSelectionMutation) async throws
}
