import SwiftUI

/// Following sources: collapsible **Publications** section only (no add-publication control).
struct FollowingPublicationSidebarTree: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @State private var publicationsExpanded = true

    var body: some View {
        Section(isExpanded: $publicationsExpanded) {
            if appModel.followingTabPublications.isEmpty,
               appModel.sidebarFetching,
               !appModel.hasSidebarSnapshot
            {
                ForEach(0 ..< 4, id: \.self) { _ in
                    SidebarSkeletonRow()
                }
            } else {
                ForEach(appModel.followingTabPublications) { publication in
                    publicationRow(publication)
                }
            }
        } header: {
            SidebarSectionLabel(
                title: "Publications",
                unreadCount: appModel.sumUnread(for: appModel.followingTabPublications)
            )
        }
    }

    private func publicationRow(_ publication: DiscoveredPublication) -> some View {
        PublicationSidebarRow(
            publication: publication,
            unreadCount: appModel.unreadCachedBadge(for: publication)
        )
        .readerClearListRow()
        .tag(SidebarSelection.publication(publication.publicationId))
    }
}
