import SwiftUI

/// Following sources: collapsible **Publications** section only (no add-publication control).
struct FollowingPublicationSidebarTree: View {
    @Environment(SocialWireAppModel.self) private var appModel
    var onPublicationTap: ((DiscoveredPublication) -> Void)? = nil

    var body: some View {
        @Bindable var model = appModel
        let tree = appModel.sidebarTreeViewModel

        Section(isExpanded: $model.sidebarPublicationsSectionExpanded) {
            if appModel.followingTabPublications.isEmpty,
               tree.loadingFlags.sidebarFetching,
               !tree.loadingFlags.hasSidebarSnapshot
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
                unreadCount: tree.followingSectionUnread
            )
        }
        .onChange(of: model.sidebarPublicationsSectionExpanded) { _, _ in
            appModel.noteSidebarExpandedPresentationChanged()
        }
    }

    private func publicationRow(_ publication: DiscoveredPublication) -> some View {
        Button {
            appModel.selectedSidebar = .publication(publication.publicationId)
            onPublicationTap?(publication)
        } label: {
            PublicationSidebarRow(
                publication: publication,
                unreadCount: tree.unreadCount(for: publication)
            )
            .readerFullWidthTapLabel()
        }
        .buttonStyle(.plain)
        .readerClearListRow()
        .tag(SidebarSelection.publication(publication.publicationId))
    }
}
