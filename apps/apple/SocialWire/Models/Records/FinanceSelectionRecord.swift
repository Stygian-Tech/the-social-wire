import CryptoKit
import Foundation

struct FinanceSelectionRecord: Codable, Equatable, Sendable {
    static let collection = "app.thesocialwire.finance.selection"
    var type: String = collection
    let kind: String
    let reference: String
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case type = "$type"
        case kind, reference, createdAt, updatedAt
    }

    var key: String { Self.key(kind: kind, reference: reference) }
    static func key(kind: String, reference: String) -> String {
        SHA256.hash(data: Data("\(kind):\(reference)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}
