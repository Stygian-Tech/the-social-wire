import SwiftUI

/// Following sources: collapsible **Publications** section only (no add-publication control).
struct FollowingPublicationSidebarTree: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @State private var publicationsExpanded = true

    var body: some View {
        Section(isExpanded: $publicationsExpanded) {
            if appModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .readerClearListRow()
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
