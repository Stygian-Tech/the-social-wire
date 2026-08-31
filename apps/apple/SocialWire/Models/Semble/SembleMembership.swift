import Foundation

struct SembleMembership: Codable, Equatable, Sendable {
    let linkUri: String?
    let linkCid: String?
    let authorDid: String
    let addedBy: String
    let addedAt: String?
    let viewerOwned: Bool
}
