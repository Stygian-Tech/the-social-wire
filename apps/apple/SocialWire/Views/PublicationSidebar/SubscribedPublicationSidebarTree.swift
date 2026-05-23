import SwiftUI

/// Subscribed sources: collapsible **Folders** and **Publications** list sections (not `DisclosureGroup` rows).
struct SubscribedPublicationSidebarTree: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Binding var showingNewFolder: Bool
    @Binding var showingAddPublication: Bool
    @State private var foldersExpanded = true
    @State private var publicationsExpanded = true
    @State private var expandedFolderRkeys: Set<String> = []

    var body: some View {
        Section(isExpanded: $foldersExpanded) {
            if appModel.folders.isEmpty, appModel.sidebarFetching, !appModel.hasSidebarSnapshot {
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
            SidebarSectionLabel(title: "Folders", unreadCount: foldersSectionUnread)
        }

        Section(isExpanded: $publicationsExpanded) {
            if appModel.subscribedUnfolderedPublications.isEmpty,
               appModel.sidebarFetching,
               !appModel.hasSidebarSnapshot
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
                unreadCount: appModel.sumUnread(for: appModel.subscribedUnfolderedPublications)
            )
        }
    }

    @ViewBuilder
    private func folderSection(_ folder: RepoRecord<FolderRecord>) -> some View {
        let folderRkey = rkey(from: folder.uri)
        let pubs = appModel.publications(in: folder)
        let isExpanded = expandedFolderRkeys.contains(folderRkey)

        Button {
            if isExpanded {
                expandedFolderRkeys.remove(folderRkey)
            } else {
                expandedFolderRkeys.insert(folderRkey)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                Text(folder.value.name)
                    .lineLimit(1)
                Spacer(minLength: 6)
                SidebarCountLabel(count: appModel.sumUnread(for: pubs))
            }
        }
        .readerClearListRow()
        .swipeActions {
            Button("Delete", role: .destructive) {
                Task { await appModel.deleteFolder(folder) }
            }
        }

        if isExpanded {
            if pubs.isEmpty, appModel.folderPublicationsLoading {
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
        PublicationSidebarRow(
            publication: publication,
            unreadCount: appModel.unreadCachedBadge(for: publication)
        )
        .readerClearListRow()
        .tag(SidebarSelection.publication(publication.publicationId))
    }

    private var foldersSectionUnread: Int {
        appModel.folders.reduce(0) { total, folder in
            total + appModel.sumUnread(for: appModel.publications(in: folder))
        }
    }
}
