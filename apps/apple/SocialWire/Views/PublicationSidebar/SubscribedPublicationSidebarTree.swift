import SwiftUI

/// Subscribed sources: collapsible **Folders** and **Publications** list sections (not `DisclosureGroup` rows).
struct SubscribedPublicationSidebarTree: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Binding var showingNewFolder: Bool
    @Binding var showingAddPublication: Bool
    @State private var foldersExpanded = true
    @State private var publicationsExpanded = true

    var body: some View {
        Section(isExpanded: $foldersExpanded) {
            if appModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .readerClearListRow()
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
            if !appModel.isLoading {
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
        let pubs = appModel.publications(in: folder)
        DisclosureGroup {
            ForEach(pubs) { publication in
                publicationRow(publication)
            }
            if pubs.isEmpty {
                Text("No publications in this folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .readerClearListRow()
            }
        } label: {
            HStack {
                Text(folder.value.name)
                    .lineLimit(1)
                Spacer(minLength: 6)
                SidebarCountLabel(count: appModel.sumUnread(for: pubs))
            }
            .readerClearListRow()
        }
        .swipeActions {
            Button("Delete", role: .destructive) {
                Task { await appModel.deleteFolder(folder) }
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
