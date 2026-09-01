import Foundation

struct SavedTagMutationProgress: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case rename(replacement: String)
        case delete
    }

    let tag: String
    let action: Action
    var scanned: Int = 0
    var matched: Int = 0
    var updated: Int = 0
    var cursor: String?
    var errorMessage: String?

    var isComplete: Bool { cursor == nil && errorMessage == nil }

    mutating func applyPage(
        scanned: Int,
        matched: Int,
        updated: Int,
        cursor: String?
    ) {
        self.scanned += scanned
        self.matched += matched
        self.updated += updated
        self.cursor = cursor?.trimmingCharacters(in: .whitespacesAndNewlines)
        if self.cursor?.isEmpty == true { self.cursor = nil }
        errorMessage = nil
    }
}
