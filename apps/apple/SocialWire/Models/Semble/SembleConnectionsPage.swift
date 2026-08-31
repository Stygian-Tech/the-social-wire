import Foundation

struct SembleConnectionsPage: Codable, Equatable, Sendable {
    let connections: [SembleConnection]
    let cursor: String?
}
