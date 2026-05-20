import Foundation

extension SidebarPublicationRowDTO {
    func toDiscoveredPublication() -> DiscoveredPublication {
        DiscoveredPublication(
            publicationId: publicationId,
            subscriptionPublicationId: subscriptionPublicationId,
            authorDid: authorDid,
            authorHandle: authorHandle ?? authorDid,
            title: title,
            iconUrl: iconUrl,
            avatarUrl: avatarUrl,
            discoveredAt: discoveredAt
        )
    }
}

extension PublicationSidebarResponseDTO {
    func scopesByPublicationId() -> [String: PublicationAppViewScopeDTO] {
        Dictionary(
            uniqueKeysWithValues: allPublicationRows.map { ($0.publicationId, $0.appViewScope) }
        )
    }
}
