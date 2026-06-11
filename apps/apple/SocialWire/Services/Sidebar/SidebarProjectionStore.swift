import Foundation

/// Gateway sidebar projection rows, folder map, and AppView scopes.
@MainActor
final class SidebarProjectionStore {
    var subscribedUnfoldered: [DiscoveredPublication] = []
    var myPublications: [DiscoveredPublication] = []
    var followingTab: [DiscoveredPublication] = []
    var allPublicationRows: [DiscoveredPublication] = []
    var folderMap: [String: [DiscoveredPublication]] = [:]
    var scopesByPublicationId: [String: PublicationAppViewScopeDTO] = [:]
    var cachedPriorityProjection: PublicationSidebarResponseDTO?
    var cachedFolderSections: [PublicationFolderSectionDTO]?
    var cachedFolderRows: [SidebarPublicationRowDTO]?

    func reset() {
        subscribedUnfoldered = []
        myPublications = []
        followingTab = []
        allPublicationRows = []
        folderMap = [:]
        scopesByPublicationId = [:]
        cachedPriorityProjection = nil
        cachedFolderSections = nil
        cachedFolderRows = nil
    }

    func sidebarPublicationIds() -> [String] {
        Array(
            Set(
                allPublicationRows.map(\.publicationId)
                    + myPublications.map(\.publicationId)
                    + subscribedUnfoldered.map(\.publicationId)
                    + followingTab.map(\.publicationId)
            )
        )
    }

    func publicationMatchingId(_ publicationId: String) -> DiscoveredPublication? {
        var seen = Set<String>()
        let candidates = allPublicationRows + myPublications + subscribedUnfoldered + followingTab
        for publication in candidates where seen.insert(publication.publicationId).inserted {
            if PublicationUnreadCountLookup.publicationIdsMatch(
                publication.publicationId,
                publicationId
            ) {
                return publication
            }
        }
        return nil
    }
}
