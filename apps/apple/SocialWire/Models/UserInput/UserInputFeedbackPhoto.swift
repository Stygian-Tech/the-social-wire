import Foundation

struct UserInputFeedbackPhoto: Identifiable, Equatable, Sendable {
    let id: UUID
    let data: Data
    let mimeType: String
    let name: String

    init(id: UUID = UUID(), data: Data, mimeType: String, name: String) {
        self.id = id
        self.data = data
        self.mimeType = mimeType
        self.name = name
    }
}
