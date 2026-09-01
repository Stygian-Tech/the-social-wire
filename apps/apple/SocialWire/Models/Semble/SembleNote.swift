import Foundation

struct SembleNote: Codable, Equatable, Sendable {
    let uri: String?
    let text: String
    let authorDid: String
    let editable: Bool
}
