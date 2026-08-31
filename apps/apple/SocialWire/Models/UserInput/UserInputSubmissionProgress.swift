import Foundation

enum UserInputSubmissionProgress: Equatable, Sendable {
    case uploadingPhoto(completed: Int, total: Int)
    case posting
}
