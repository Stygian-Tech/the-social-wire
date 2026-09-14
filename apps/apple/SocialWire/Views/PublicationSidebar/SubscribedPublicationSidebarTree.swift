import SwiftUI

/// Subscribed sources: collapsible **Folders** and **Publications** list sections (not `DisclosureGroup` rows).
struct SubscribedPublicationSidebarTree: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Binding var showingNewFolder: Bool
    @Binding var showingAddPublication: Bool
    var onFolderTap: (() -> Void)? = nil
    var onPublicationTap: ((DiscoveredPublication) -> Void)? = nil
    @State private var folderPendingDelete: RepoRecord<FolderRecord>?
    @State private var folderPendingEdit: RepoRecord<FolderRecord>?
    @State private var folderDeleteFeedback = 0
    @State private var publicationPendingUnsubscribe: DiscoveredPublication?

    var body: some View {
        @Bindable var model = appModel

        let tree = appModel.sidebarTreeViewModel

        DisclosureGroup(isExpanded: $model.sidebarFoldersSectionExpanded) {
            if appModel.folders.isEmpty,
               tree.loadingFlags.sidebarFetching,
               !tree.loadingFlags.hasSidebarSnapshot
            {
                ForEach(0 ..< 3, id: \.self) { _ in
                    SidebarSkeletonRow()
                }
            } else {
                ForEach(appModel.folders) { folder in
                    folderDisclosure(folder, tree: tree)
                }
            }
        } label: {
            SidebarSectionLabel(title: "Folders", unreadCount: 0)
        }
        .readerSidebarListRow()
        .onChange(of: model.sidebarFoldersSectionExpanded) { _, _ in
            appModel.noteSidebarExpandedPresentationChanged()
        }

        DisclosureGroup(isExpanded: $model.sidebarPublicationsSectionExpanded) {
            if appModel.subscribedUnfolderedPublications.isEmpty,
               tree.loadingFlags.sidebarFetching,
               !tree.loadingFlags.hasSidebarSnapshot
            {
                ForEach(0 ..< 4, id: \.self) { _ in
                    SidebarSkeletonRow()
                }
            } else {
                ForEach(appModel.subscribedUnfolderedPublications) { publication in
                    publicationRow(publication, tree: tree)
                }
            }
        } label: {
            SidebarSectionLabel(title: "Publications", unreadCount: 0)
        }
        .readerSidebarListRow()
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
        .sheet(item: $folderPendingEdit) { folder in
            EditFolderView(folder: folder)
        }
        .confirmationDialog(
            "Unsubscribe from publication?",
            isPresented: Binding(
                get: { publicationPendingUnsubscribe != nil },
                set: { if !$0 { publicationPendingUnsubscribe = nil } }
            ),
            titleVisibility: .visible,
            presenting: publicationPendingUnsubscribe
        ) { publication in
            Button("Unsubscribe", role: .destructive) {
                Task { await appModel.unsubscribe(from: publication) }
                publicationPendingUnsubscribe = nil
            }
            Button("Cancel", role: .cancel) {
                publicationPendingUnsubscribe = nil
            }
        } message: { publication in
            Text("Remove \"\(publication.title)\" from your subscriptions?")
        }
    }

    private func folderDisclosure(
        _ folder: RepoRecord<FolderRecord>,
        tree: SidebarTreeViewModel
    ) -> some View {
        let folderRkey = rkey(from: folder.uri)
        let publications = appModel.publications(in: folder)
        let isExpanded = appModel.sidebarExpandedFolderRkeys.contains(folderRkey)

        return DisclosureGroup(
            isExpanded: Binding(
                get: { isExpanded },
                set: { expanded in
                    guard expanded != isExpanded else { return }
                    appModel.toggleSidebarFolderExpanded(rkey: folderRkey)
                }
            )
        ) {
            if publications.isEmpty, tree.loadingFlags.folderPublicationsLoading {
                ForEach(0 ..< 2, id: \.self) { _ in
                    SidebarSkeletonRow()
                }
            } else {
                ForEach(publications) { publication in
                    publicationRow(publication, tree: tree)
                }
                if publications.isEmpty {
                    Text("No publications in this folder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .readerSidebarListRow()
                }
            }
        } label: {
            Button {
                Task {
                    await appModel.selectFolderFeed(folderRkey: folderRkey)
                    onFolderTap?()
                }
            } label: {
                HStack(spacing: 8) {
                    Text(folder.value.name)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    SidebarCountLabel(count: tree.folderUnread(rkey: folderRkey))
                }
                .readerFullWidthTapLabel()
            }
            .buttonStyle(.plain)
        }
        .readerSidebarListRow()
        .contextMenu {
            Button {
                folderPendingEdit = folder
            } label: {
                Label("Edit Folder", systemImage: "pencil")
            }
            Button(role: .destructive) {
                folderPendingDelete = folder
            } label: {
                Label("Delete Folder", systemImage: "trash")
            }
        }
        .swipeActions {
            Button("Delete", role: .destructive) {
                folderPendingDelete = folder
            }
        }
    }

    private func publicationRow(
        _ publication: DiscoveredPublication,
        tree: SidebarTreeViewModel
    ) -> some View {
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
        .readerSidebarListRow()
        .tag(SidebarSelection.publication(publication.publicationId))
        .contextMenu {
            Button {
                Task { await appModel.refreshPublication(publication) }
            } label: {
                Label("Refresh Publication", systemImage: "arrow.clockwise")
            }
            Button(role: .destructive) {
                publicationPendingUnsubscribe = publication
            } label: {
                Label("Unsubscribe", systemImage: "minus.circle")
            }
        }
    }
}
