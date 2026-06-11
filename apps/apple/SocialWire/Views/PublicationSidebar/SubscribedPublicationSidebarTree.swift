import SwiftUI

/// Subscribed sources: collapsible **Folders** and **Publications** list sections (not `DisclosureGroup` rows).
struct SubscribedPublicationSidebarTree: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Binding var showingNewFolder: Bool
    @Binding var showingAddPublication: Bool
    var onPublicationTap: ((DiscoveredPublication) -> Void)? = nil
    @State private var folderPendingDelete: RepoRecord<FolderRecord>?
    @State private var folderDeleteFeedback = 0

    var body: some View {
        @Bindable var model = appModel

        let tree = appModel.sidebarTreeViewModel

        Section(isExpanded: $model.sidebarFoldersSectionExpanded) {
            if appModel.folders.isEmpty,
               tree.loadingFlags.sidebarFetching,
               !tree.loadingFlags.hasSidebarSnapshot
            {
                ForEach(0 ..< 3, id: \.self) { _ in
                    SidebarSkeletonRow()
                }
            } else {
                ForEach(appModel.folders) { folder in
                    folderSection(folder)
                }
                Button {
                    showingNewFolder = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .readerClearListRow()
            }
        } header: {
            SidebarSectionLabel(title: "Folders", unreadCount: tree.foldersSectionUnread)
        }
        .onChange(of: model.sidebarFoldersSectionExpanded) { _, _ in
            appModel.noteSidebarExpandedPresentationChanged()
        }

        Section(isExpanded: $model.sidebarPublicationsSectionExpanded) {
            if appModel.subscribedUnfolderedPublications.isEmpty,
               tree.loadingFlags.sidebarFetching,
               !tree.loadingFlags.hasSidebarSnapshot
            {
                ForEach(0 ..< 4, id: \.self) { _ in
                    SidebarSkeletonRow()
                }
            } else {
                ForEach(appModel.subscribedUnfolderedPublications) { publication in
                    publicationRow(publication)
                }
                Button {
                    showingAddPublication = true
                } label: {
                    Label("Add Publication", systemImage: "plus.circle")
                }
                .readerClearListRow()
            }
        } header: {
            SidebarSectionLabel(
                title: "Publications",
                unreadCount: tree.publicationsSectionUnread
            )
        }
        .onChange(of: model.sidebarPublicationsSectionExpanded) { _, _ in
            appModel.noteSidebarExpandedPresentationChanged()
        }
        .confirmationDialog(
            "Delete folder?",
            isPresented: Binding(
                get: { folderPendingDelete != nil },
                set: { if !$0 { folderPendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: folderPendingDelete
        ) { folder in
            Button("Delete", role: .destructive) {
                Task { await appModel.deleteFolder(folder) }
                folderDeleteFeedback += 1
                folderPendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                folderPendingDelete = nil
            }
        } message: { folder in
            Text("This deletes \"\(folder.value.name)\" and does not unsubscribe from its publications.")
        }
        .sensoryFeedback(.success, trigger: folderDeleteFeedback)
    }

    @ViewBuilder
    private func folderSection(_ folder: RepoRecord<FolderRecord>) -> some View {
        let folderRkey = rkey(from: folder.uri)
        let pubs = appModel.publications(in: folder)
        let isExpanded = appModel.sidebarExpandedFolderRkeys.contains(folderRkey)

        Button {
            appModel.toggleSidebarFolderExpanded(rkey: folderRkey)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                    .accessibilityHidden(true)
                Text(folder.value.name)
                    .lineLimit(1)
                Spacer(minLength: 6)
                SidebarCountLabel(count: tree.folderUnread(rkey: folderRkey))
            }
            .readerFullWidthTapLabel()
        }
        .readerClearListRow()
        .swipeActions {
            Button("Delete", role: .destructive) {
                folderPendingDelete = folder
            }
        }

        if isExpanded {
            if pubs.isEmpty, tree.loadingFlags.folderPublicationsLoading {
                ForEach(0 ..< 2, id: \.self) { _ in
                    SidebarSkeletonRow()
                }
            } else {
                ForEach(pubs) { publication in
                    publicationRow(publication)
                }
                if pubs.isEmpty {
                    Text("No publications in this folder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .readerClearListRow()
                }
            }
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
        .contextMenu {
            Button {
                Task { await appModel.refreshPublication(publication) }
            } label: {
                Label("Refresh Publication", systemImage: "arrow.clockwise")
            }
        }
    }
}
