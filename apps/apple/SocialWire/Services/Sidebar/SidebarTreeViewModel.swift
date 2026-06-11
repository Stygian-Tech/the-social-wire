import Foundation

struct SidebarLoadingFlags: Equatable {
    var sidebarFetching: Bool
    var folderPublicationsLoading: Bool
    var hasSidebarSnapshot: Bool
}

/// Narrow observation surface for publication sidebar SwiftUI trees.
struct SidebarTreeViewModel: Equatable {
    var folders: [RepoRecord<FolderRecord>]
    var folderPublications: [String: [DiscoveredPublication]]
    var unfoldered: [DiscoveredPublication]
    var following: [DiscoveredPublication]
    var unreadByPublicationId: [String: Int]
    var foldersSectionUnread: Int
    var publicationsSectionUnread: Int
    var followingSectionUnread: Int
    var folderUnreadByRkey: [String: Int]
    var loadingFlags: SidebarLoadingFlags

    func unreadCount(for publication: DiscoveredPublication) -> Int {
        PublicationUnreadCountLookup.lookup(
            in: unreadByPublicationId,
            publicationId: publication.publicationId
        )
    }

    func folderUnread(rkey: String) -> Int {
        folderUnreadByRkey[rkey] ?? 0
    }
}
