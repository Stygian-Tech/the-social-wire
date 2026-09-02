import Foundation

struct MarkReadBeforeResponse: Decodable, Sendable {
    let marked: Int
    let entryIds: [String]
    let readAt: String
    let unreadCounts: [String: Int]
}
