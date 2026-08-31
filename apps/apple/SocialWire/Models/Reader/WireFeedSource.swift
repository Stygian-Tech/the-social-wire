import Foundation

struct WireFeedSource: Codable, Equatable, Sendable {
    let name: String
    let domain: String
    let publication: String?
    let author: String?
    let publicationKey: String?
    let homepageUrl: String?
    let iconUrl: String?

    init(
        name: String,
        domain: String,
        publication: String? = nil,
        author: String? = nil,
        publicationKey: String? = nil,
        homepageUrl: String? = nil,
        iconUrl: String? = nil
    ) {
        self.name = name
        self.domain = domain
        self.publication = publication
        self.author = author
        self.publicationKey = publicationKey
        self.homepageUrl = homepageUrl
        self.iconUrl = iconUrl
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? domain : trimmed
    }
}
