import Foundation

protocol WireBaselineLabelRefreshing: Sendable {
  func refresh(asOf: Date) async throws
}
