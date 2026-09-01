import Foundation

struct UserInputFeedbackInput: Equatable, Sendable {
    let title: String
    let body: String?
    let tags: [String]
    let photos: [UserInputFeedbackPhoto]
}
