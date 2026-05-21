import Foundation

enum PublicationProjectionJSON {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

struct PublicationAppViewScopeDTO: Codable, Equatable, Sendable {
    let authorDid: String
    let publicationAtUri: String?
    let publicationScopeAtUris: [String]
    let publicationSiteUrls: [String]
}

struct SidebarPublicationRowDTO: Codable, Equatable, Sendable {
    let publicationId: String
    let subscriptionPublicationId: String?
    let authorDid: String
    let authorHandle: String?
    let title: String
    let iconUrl: String?
    let avatarUrl: String?
    let discoveredAt: String
    let appViewScope: PublicationAppViewScopeDTO
    let unreadCount: Int?
}

struct PublicationFolderSectionDTO: Codable, Equatable, Sendable {
    let folderRkey: String
    let folderUri: String
    let publications: [SidebarPublicationRowDTO]
}

struct PublicationSidebarResponseDTO: Codable, Sendable {
    let viewerDid: String
    let folders: [PublicationFolderDTO]?
    let publicationPrefs: [PublicationPrefsDTO]?
    let folderSections: [PublicationFolderSectionDTO]?
    let allPublicationRows: [SidebarPublicationRowDTO]
    let myPublications: [SidebarPublicationRowDTO]
    let subscribedUnfoldered: [SidebarPublicationRowDTO]
    let followingTabPublications: [SidebarPublicationRowDTO]
    let enrollAuthorDids: [String]
    let refreshedAt: String
    let unreadCountsByPublicationId: [String: Int]?
}

struct PublicationFolderDTO: Codable, Sendable {
    let uri: String
    let rkey: String
    let value: [String: JSONValue]?
}

struct PublicationPrefsDTO: Codable, Sendable {
    let uri: String
    let publicationId: String
    let value: [String: JSONValue]?
}

struct GatewayRecordWriteResponseDTO: Codable, Sendable {
    let uri: String
    let rkey: String
}

struct GatewayMarkAllReadResponseDTO: Codable, Sendable {
    let marked: Int
}

struct ResolveAddPublicationRequestBody: Codable, Sendable {
    let input: String
}

struct ResolveAddPublicationResponseDTO: Codable, Sendable {
    let result: ResolveAddPublicationResultDTO?
    let error: String?
}

struct ResolveAddPublicationResultDTO: Codable, Sendable {
    let kind: String
    let publicationAtUri: String?
    let feedUrl: String?
    let title: String?
    let siteUrl: String?
    let feedIconUrl: String?
}
