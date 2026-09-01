import Foundation

enum WireArticleFeedbackValue: String, Codable, Equatable, Sendable {
    case good
    case notGood = "not_good"
}
