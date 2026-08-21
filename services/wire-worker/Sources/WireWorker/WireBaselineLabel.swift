import Foundation

struct WireBaselineLabel: Equatable, Sendable {
  let canonicalKey: String
  let labelKey: String
  let labelValue: String
  let source: String
  let appliedAt: Date
  let expiresAt: Date
}
