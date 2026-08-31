import Foundation

struct UserInputTag: Codable, Equatable, Identifiable, Sendable {
    let label: String
    let value: String

    var id: String { value }

    static let localDefaults: [UserInputTag] = [
        UserInputTag(label: "Bug", value: "bug"),
        UserInputTag(label: "Feature", value: "feature"),
        UserInputTag(label: "Question", value: "question"),
        UserInputTag(label: "Comment", value: "comment"),
    ]
}
