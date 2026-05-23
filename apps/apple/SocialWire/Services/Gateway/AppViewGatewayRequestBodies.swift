import Foundation

struct AppViewReadMarkBody: Encodable, Sendable {
    let subjectUri: String
    let readAt: String
}

struct AppViewReadMarkDeleteBody: Encodable, Sendable {
    let subjectUri: String
}

struct AppViewEnrollBody: Encodable, Sendable {
    let authorDids: [String]
    let feedUrls: [String]

    init(authorDids: [String], feedUrls: [String] = []) {
        self.authorDids = authorDids
        self.feedUrls = feedUrls
    }
}

struct GatewayFolderWriteBody: Encodable, Sendable {
    let name: String
    let icon: String?
    let iconImage: String?
    let sortOrder: Int?

    init(name: String, icon: String? = nil, iconImage: String? = nil, sortOrder: Int? = nil) {
        self.name = name
        self.icon = icon
        self.iconImage = iconImage
        self.sortOrder = sortOrder
    }
}

struct GatewayPublicationPrefsWriteBody: Encodable, Sendable {
    let publicationId: String
    let folderId: String?
    let sortOrder: Int?
    let hidden: Bool?
    let existingRkey: String?
}

struct GatewayPublicationSubscriptionWriteBody: Encodable, Sendable {
    let publication: String
}

struct GatewayRssSubscriptionWriteBody: Encodable, Sendable {
    let feedUrl: String
    let title: String?
    let siteUrl: String?
}

enum GatewayMarkAllReadScopeDTO: Encodable, Sendable {
    case publication(publicationId: String)
    case folder(folderRkey: String)
    case subscribed
    case following

    private enum CodingKeys: String, CodingKey {
        case kind
        case publicationId
        case folderRkey
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .publication(publicationId):
            try container.encode("publication", forKey: .kind)
            try container.encode(publicationId, forKey: .publicationId)
        case let .folder(folderRkey):
            try container.encode("folder", forKey: .kind)
            try container.encode(folderRkey, forKey: .folderRkey)
        case .subscribed:
            try container.encode("subscribed", forKey: .kind)
        case .following:
            try container.encode("following", forKey: .kind)
        }
    }
}

struct GatewayMarkAllReadBody: Encodable, Sendable {
    let scope: GatewayMarkAllReadScopeDTO
}
