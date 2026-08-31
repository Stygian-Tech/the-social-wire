import Foundation

struct SembleCollectionItem: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let cardUri: String
    let cardCid: String?
    let cardType: String
    let url: String?
    let title: String?
    let description: String?
    let image: String?
    let siteName: String?
    let publishedAt: String?
    let createdAt: String?
    let membership: SembleMembership?
    let contributor: SembleContributor
    let note: SembleNote?
    let unlinkAvailable: Bool

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        cardUri = try container.decode(String.self, forKey: .cardUri)
        cardCid = try container.decodeIfPresent(String.self, forKey: .cardCid)
        cardType = try container.decode(String.self, forKey: .cardType)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        image = try container.decodeIfPresent(String.self, forKey: .image)
        siteName = try container.decodeIfPresent(String.self, forKey: .siteName)
        publishedAt = try container.decodeIfPresent(String.self, forKey: .publishedAt)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        membership = try container.decodeIfPresent(SembleMembership.self, forKey: .membership)
        contributor = try container.decode(SembleContributor.self, forKey: .contributor)
        note = try container.decodeIfPresent(SembleNote.self, forKey: .note)
        unlinkAvailable = try container.decodeIfPresent(Bool.self, forKey: .unlinkAvailable) ?? false
    }

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let url, let host = URL(string: url)?.host { return host }
        return cardType == "NOTE" ? (note?.text ?? "Note") : "Saved Link"
    }
}
