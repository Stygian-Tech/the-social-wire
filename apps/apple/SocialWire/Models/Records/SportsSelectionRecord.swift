import CryptoKit
import Foundation

struct SportsSelectionRecord: Codable, Equatable, Sendable {
    static let collection = "app.thesocialwire.sports.selection"
    var type: String = collection
    let reference: String
    let action: String
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case type = "$type"
        case reference, action, createdAt, updatedAt
    }

    var key: String { Self.key(reference: reference) }
    static func key(reference: String) -> String {
        SHA256.hash(data: Data(reference.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
