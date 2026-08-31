import Foundation

struct ReadLaterConnectionPreferenceRecord: Codable, Equatable, Sendable {
    var connectedAt: String?
    var accountLabel: String?
    var collectionUri: String?
    var collectionName: String?

    init(
        connectedAt: String? = nil,
        accountLabel: String? = nil,
        collectionUri: String? = nil,
        collectionName: String? = nil
    ) {
        self.connectedAt = connectedAt
        self.accountLabel = accountLabel
        self.collectionUri = collectionUri
        self.collectionName = collectionName
    }

    enum CodingKeys: String, CodingKey {
        case connectedAt
        case accountLabel
        case collectionUri
        case collectionName
    }
}
