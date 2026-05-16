import Foundation

struct AuthSession: Codable, Equatable, Sendable {
    var did: String
    var pdsURL: URL
    /// Authorization-server token endpoint (from `/.well-known/oauth-authorization-server`).
    var tokenEndpoint: URL
    var accessToken: String
    var refreshToken: String
    var tokenType: String
    var expiresAt: Date
}

struct TokenResponse: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String
    let tokenType: String
    let expiresIn: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
    }
}

struct OAuthProtectedResourceMetadata: Decodable, Sendable {
    let authorizationServers: [String]

    enum CodingKeys: String, CodingKey {
        case authorizationServers = "authorization_servers"
    }
}

struct AuthorizationServerMetadata: Decodable, Sendable {
    let issuer: String
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let pushedAuthorizationRequestEndpoint: URL

    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case pushedAuthorizationRequestEndpoint = "pushed_authorization_request_endpoint"
    }
}

struct PARResponse: Decodable, Sendable {
    let requestURI: String
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case requestURI = "request_uri"
        case expiresIn = "expires_in"
    }
}

struct RepoRecord<Value: Codable & Sendable>: Codable, Identifiable, Sendable {
    let uri: String
    let cid: String?
    let value: Value

    var id: String { uri }
}

struct GenericRepoRecord: Codable, Identifiable, Sendable {
    let uri: String
    let cid: String?
    let value: JSONValue

    var id: String { uri }
}

struct ListRecordsResponse<Value: Codable & Sendable>: Codable, Sendable {
    let records: [RepoRecord<Value>]
    let cursor: String?
}

struct GenericListRecordsResponse: Codable, Sendable {
    let records: [GenericRepoRecord]
    let cursor: String?
}

struct GetRecordResponse<Value: Codable & Sendable>: Codable, Sendable {
    let uri: String
    let cid: String?
    let value: Value
}

struct ResolveHandleResponse: Codable, Sendable {
    let did: String
}

struct DIDDocument: Codable, Sendable {
    struct Service: Codable, Sendable {
        let id: String
        let type: String?
        let serviceEndpoint: String
    }

    let service: [Service]?
}

struct FollowProfile: Codable, Identifiable, Sendable {
    let did: String
    let handle: String
    let displayName: String?
    let avatar: String?

    var id: String { did }
}

struct FollowsResponse: Codable, Sendable {
    let follows: [FollowProfile]
    let cursor: String?
}

struct ProfileViewResponse: Codable, Sendable {
    struct Viewer: Codable, Sendable {
        let like: String?
        let repost: String?
    }

    let uri: String
    let cid: String?
    let viewer: Viewer?
}

struct PostsResponse: Codable, Sendable {
    let posts: [ProfileViewResponse]
}

struct StrongRef: Codable, Equatable, Sendable {
    let uri: String
    let cid: String
}

struct FolderRecord: Codable, Equatable, Sendable {
    let type: String
    var name: String
    var sortOrder: Int?
    var icon: String?
    var iconImage: String?
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case type = "$type"
        case name
        case sortOrder
        case icon
        case iconImage
        case createdAt
    }
}

struct PublicationPrefsRecord: Codable, Equatable, Sendable {
    let type: String
    var publicationId: String
    var folderId: String?
    var sortOrder: Int?
    var hidden: Bool?
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case type = "$type"
        case publicationId
        case folderId
        case sortOrder
        case hidden
        case createdAt
    }
}

struct PreferencesRecord: Codable, Equatable, Sendable {
    let type: String
    var readLaterService: String?
    var createdAt: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case type = "$type"
        case readLaterService
        case createdAt
        case updatedAt
    }
}

struct PublicationSubscriptionRecord: Codable, Equatable, Sendable {
    let type: String
    var publication: String

    enum CodingKeys: String, CodingKey {
        case type = "$type"
        case publication
    }
}

struct SkyreaderFeedSubscriptionRecord: Codable, Equatable, Sendable {
    let type: String
    var createdAt: String
    var updatedAt: String?
    var feedUrl: String?
    var title: String?
    var siteUrl: String?
    var source: String?
    var sourceType: String?
    var customTitle: String?
    var customIconUrl: String?

    enum CodingKeys: String, CodingKey {
        case type = "$type"
        case createdAt
        case updatedAt
        case feedUrl
        case title
        case siteUrl
        case source
        case sourceType
        case customTitle
        case customIconUrl
    }
}

struct LatrSavedExternalRecord: Codable, Equatable, Sendable {
    let type: String
    var url: String
    var normalizedUrl: String
    var fingerprint: String
    var createdAt: String
    var title: String?
    var excerpt: String?
    var site: String?
    var image: String?
    var language: String?
    var publishedAt: String?
    var author: String?

    enum CodingKeys: String, CodingKey {
        case type = "$type"
        case url
        case normalizedUrl
        case fingerprint
        case createdAt
        case title
        case excerpt
        case site
        case image
        case language
        case publishedAt
        case author
    }
}

struct LatrSavedItemRecord: Codable, Equatable, Sendable {
    let type: String
    var subjectUri: String
    var savedAt: String
    var state: String?
    var tags: [String]?
    var note: String?
    var lastOpenedAt: String?

    enum CodingKeys: String, CodingKey {
        case type = "$type"
        case subjectUri
        case savedAt
        case state
        case tags
        case note
        case lastOpenedAt
    }
}

struct EntryReadStateRecord: Codable, Equatable, Sendable {
    let type: String
    var subjectUri: String
    var readAt: String
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case type = "$type"
        case subjectUri
        case readAt
        case updatedAt
    }
}

struct DiscoveredPublication: Identifiable, Codable, Equatable, Sendable {
    var publicationId: String
    var subscriptionPublicationId: String?
    var authorDid: String
    var authorHandle: String
    var title: String
    var iconUrl: String?
    var avatarUrl: String?
    var discoveredAt: String

    var id: String { publicationId }
    var displayImageURL: URL? { URL(string: iconUrl ?? avatarUrl ?? "") }
}

struct EntryListItem: Identifiable, Codable, Equatable, Sendable {
    var entryId: String
    var title: String
    var summary: String?
    var publishedAt: String
    var thumbnailUrl: String?
    var thumbnailFallbackUrl: String?

    var id: String { entryId }
}

struct EntryDetail: Identifiable, Codable, Equatable, Sendable {
    var entryId: String
    var title: String
    var publishedAt: String
    var contentHtml: String
    var originalUrl: String?
    var embedUrl: String?
    var bskyPostUri: String?
    var bskyPostCid: String?

    var id: String { entryId }
    var canonicalURL: URL? {
        guard let raw = embedUrl ?? originalUrl else { return nil }
        return URL(string: PublicURLNormalizer.normalizeHttpURLToHTTPS(raw))
    }
}

enum MergedLatrSave: Identifiable, Codable, Equatable, Hashable, Sendable {
    case external(MergedLatrExternalSave)
    case native(MergedLatrNativeSave)

    var id: String {
        switch self {
        case .external(let save): "external:\(save.normalizedUrl)"
        case .native(let save): "native:\(save.itemUri)"
        }
    }

    var title: String {
        switch self {
        case .external(let save): save.title ?? URL(string: save.url)?.host ?? save.url
        case .native(let save): save.title ?? save.subjectUri
        }
    }

    var url: URL? {
        switch self {
        case .external(let save): URL(string: save.url)
        case .native(let save): save.url.flatMap(URL.init(string:))
        }
    }

    var savedAt: String {
        switch self {
        case .external(let save): save.savedAt
        case .native(let save): save.savedAt
        }
    }
}

struct MergedLatrExternalSave: Codable, Equatable, Hashable, Sendable {
    var normalizedUrl: String
    var url: String
    var savedAt: String
    var externalRkey: String
    var itemRkey: String
    var externalUri: String
    var itemUri: String
    var subjectUri: String
    var state: String?
    var title: String?
    var excerpt: String?
    var image: String?
}

struct MergedLatrNativeSave: Codable, Equatable, Hashable, Sendable {
    var savedAt: String
    var itemRkey: String
    var itemUri: String
    var subjectUri: String
    var state: String?
    var title: String?
    var excerpt: String?
    var url: String?
    var image: String?
}

enum ReaderFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case unread = "Unread"

    var id: String { rawValue }
}

enum SidebarSelection: Hashable {
    case readingList
    case saved
    case myPublications
    case following
    case hidden
    case settings
    case folder(String)
    case publication(String)
}

enum SocialWireError: LocalizedError {
    case notAuthenticated
    case badResponse(String)
    case invalidURL
    case invalidATURI
    case unsupported

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: "Sign in to continue."
        case .badResponse(let message): message
        case .invalidURL: "The URL is invalid."
        case .invalidATURI: "The AT-URI is invalid."
        case .unsupported: "This action is not supported yet."
        }
    }
}
