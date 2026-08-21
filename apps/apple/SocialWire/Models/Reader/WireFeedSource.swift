import Foundation

struct WireFeedSource: Codable, Equatable, Sendable {
    let name: String
    let domain: String
    let publication: String?
    let author: String?

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? domain : trimmed
    }
}
