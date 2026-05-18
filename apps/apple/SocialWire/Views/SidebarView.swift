import SwiftUI

struct SidebarView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Binding var showingAddPublication: Bool
    @Binding var showingNewFolder: Bool
    @Binding var showingSettings: Bool

    @State private var foldersExpanded = true
    @State private var publicationsExpanded = true

    var body: some View {
        @Bindable var model = appModel

        List(selection: $model.selectedSidebar) {
            Section {
                Label("Saved", systemImage: "bookmark")
                    .tag(SidebarSelection.saved)
            } header: {
                Text("Read Later")
            }

            Section {
                Picker("Publication Source", selection: $model.publicationSidebarTab) {
                    ForEach(PublicationSidebarTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
                .accessibilityLabel("Publication Source")

                if appModel.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                } else if model.publicationSidebarTab == .subscribed {
                    subscribedSections
                } else {
                    followingSections
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("The Social Wire")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showingAddPublication = true
                } label: {
                    Label("Add Publication", systemImage: "plus")
                }
                Button {
                    Task { await appModel.refreshAll() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(appModel.isLoading)
            }
        }
        .safeAreaInset(edge: .bottom) {
            SidebarFooterView(showingSettings: $showingSettings)
        }
    }

    @ViewBuilder
    private var subscribedSections: some View {
        DisclosureGroup(isExpanded: $foldersExpanded) {
            ForEach(appModel.folders) { folder in
                folderSection(folder)
            }
            Button {
                showingNewFolder = true
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
        } label: {
            SidebarSectionLabel(title: "Folders", unreadCount: foldersSectionUnread)
        }

        DisclosureGroup(isExpanded: $publicationsExpanded) {
            ForEach(appModel.subscribedUnfolderedPublications) { publication in
                publicationRow(publication)
            }
        } label: {
            SidebarSectionLabel(
                title: "Publications",
                unreadCount: appModel.sumUnread(for: appModel.subscribedUnfolderedPublications)
            )
        }
    }

    @ViewBuilder
    private var followingSections: some View {
        DisclosureGroup(isExpanded: $publicationsExpanded) {
            ForEach(appModel.followingTabPublications) { publication in
                publicationRow(publication)
            }
        } label: {
            SidebarSectionLabel(
                title: "Publications",
                unreadCount: appModel.sumUnread(for: appModel.followingTabPublications)
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
            }
        } label: {
            HStack {
                Text(folder.value.name)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if appModel.sumUnread(for: pubs) > 0 {
                    UnreadBadge(count: appModel.sumUnread(for: pubs))
                }
            }
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
        .tag(SidebarSelection.publication(publication.publicationId))
    }

    private var foldersSectionUnread: Int {
        appModel.folders.reduce(0) { total, folder in
            total + appModel.sumUnread(for: appModel.publications(in: folder))
        }
    }
}

struct SidebarSectionLabel: View {
    let title: String
    let unreadCount: Int

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.medium))
            Spacer(minLength: 6)
            if unreadCount > 0 {
                UnreadBadge(count: unreadCount)
            }
        }
    }
}

struct UnreadBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color.accentColor.opacity(0.88))
            )
            .accessibilityLabel("\(count) unread")
    }
}

struct PublicationSidebarRow: View {
    let publication: DiscoveredPublication
    let unreadCount: Int

    var body: some View {
        HStack(spacing: 10) {
            PublicationAvatar(publication: publication, size: 24)
            Text(publication.title)
                .lineLimit(1)
            Spacer(minLength: 6)
            if unreadCount > 0 {
                UnreadBadge(count: unreadCount)
            }
        }
    }
}

struct SidebarFooterView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Binding var showingSettings: Bool

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                appModel.openMyPublications()
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    profileAvatar
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        Text(appModel.viewerDID ?? "")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Your Profile and Publications")

            Divider()

            Button {
                showingSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            Button(role: .destructive) {
                appModel.signOut()
            } label: {
                Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
        }
        .background(.bar)
    }

    @ViewBuilder
    private var profileAvatar: some View {
        if let avatarURL = appModel.viewerProfile?.avatar.flatMap(URL.init(string:)) {
            AsyncImage(url: avatarURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    Image(systemName: "person.circle.fill")
                        .resizable()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(Circle())
        } else {
            Image(systemName: "person.circle.fill")
                .resizable()
                .frame(width: 40, height: 40)
                .foregroundStyle(.secondary)
        }
    }

    private var displayName: String {
        if let name = appModel.viewerProfile?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty
        {
            return name
        }
        if let handle = appModel.viewerProfile?.handle, !handle.isEmpty {
            return handle
        }
        return appModel.viewerDID ?? "Account"
    }
}
