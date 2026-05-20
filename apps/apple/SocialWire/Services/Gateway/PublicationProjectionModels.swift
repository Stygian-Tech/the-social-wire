import Foundation

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
}

struct PublicationSidebarResponseDTO: Codable, Sendable {
    let viewerDid: String
    let allPublicationRows: [SidebarPublicationRowDTO]
    let myPublications: [SidebarPublicationRowDTO]
    let subscribedUnfoldered: [SidebarPublicationRowDTO]
    let followingTabPublications: [SidebarPublicationRowDTO]
    let enrollAuthorDids: [String]
    let refreshedAt: String
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
