import Foundation

struct SembleConnection: Codable, Equatable, Identifiable, Sendable {
    let uri: String?
    let source: String
    let target: String
    let connectionType: String?
    let note: String?
    let createdAt: String?
    let updatedAt: String?
    let authorDid: String
    let editable: Bool

    var id: String { uri ?? "\(source)|\(target)|\(createdAt ?? "")" }
}
