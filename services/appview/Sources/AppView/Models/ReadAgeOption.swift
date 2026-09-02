import Foundation

struct ReadAgeOption: Codable, Sendable, Equatable {
  let days: Int
  let before: String
  let count: Int
}
