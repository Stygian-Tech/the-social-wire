import Foundation

struct SembleCollectionPage: Codable, Equatable, Sendable {
    let collections: [SembleCollectionSummary]
    let cursor: String?
}
