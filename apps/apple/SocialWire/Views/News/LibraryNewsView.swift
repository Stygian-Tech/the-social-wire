import SwiftUI

struct LibraryNewsView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    let sceneModel: NewsSceneModel

    var body: some View {
        Group {
            if appModel.selectedSidebar == .myPublications,
               appModel.selectedPublication == nil {
                LibraryPublicationList(
                    publications: appModel.myPublications,
                    onPublicationTap: openPublication
                )
            } else {
                articlesContent
            }
        }
        .navigationTitle(navigationTitle)
        .toolbar {
            if bulkReadScope != .unavailable {
                ToolbarItem(placement: .primaryAction) {
                    FeedMarkReadButton(
                        contextID: "\(appModel.viewerDID ?? ""):library:\(bulkReadScope)",
                        refreshRevision: appModel.readAgeRevision,
                        scopeTitle: bulkReadTitle,
                        loadOptions: { try await appModel.readAgeOptions(for: bulkReadScope) },
                        markAllRead: { await appModel.markRead(for: bulkReadScope) },
                        markOlderRead: { try await appModel.markRead(for: bulkReadScope, before: $0.before) },
                        markAllUnread: { await appModel.markUnread(for: bulkReadScope) }
                    )
                }
            }
        }
        .accessibilityIdentifier("news-tab-content-library")
    }

    @ViewBuilder
    private var articlesContent: some View {
        if appModel.selectedPublication != nil || appModel.hasSelectedArticleFeed {
            EntryListView(onEntryOpened: openSelectedRSSArticle)
        } else if appModel.sidebarFetching {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "Select a Publication",
                systemImage: "newspaper",
                description: Text("Choose a folder or publication from the sidebar to browse its latest stories.")
            )
        }
    }

    private var navigationTitle: String {
        appModel.selectedPublication?.title ?? "Library"
    }

    private var bulkReadScope: ReaderMarkReadScope {
        guard appModel.selectedSidebar != .myPublications else { return .unavailable }
        return ReaderMarkReadScope.selectedFeed(appModel.feedSelection)
    }

    private var bulkReadTitle: String {
        switch bulkReadScope {
        case .publication(let id):
            return appModel.publication(forId: id)?.title ?? "This Publication"
        case .folder(let key):
            return appModel.folders.first { $0.uri.hasSuffix("/\(key)") }?.value.name ?? "This Folder"
        default:
            return appModel.readerListSource.rawValue
        }
    }

    private func openSelectedRSSArticle() {
        guard let entryID = appModel.selectedEntry?.entryId else { return }
        sceneModel.navigate(to: .entry(id: entryID), in: .library)
    }

    private func openPublication(_ publication: DiscoveredPublication) {
        Task { await appModel.selectPublication(publication) }
    }
}

struct LibraryPublicationList: View {
    let publications: [DiscoveredPublication]
    let onPublicationTap: (DiscoveredPublication) -> Void

    var body: some View {
        List {
            if publications.isEmpty {
                ContentUnavailableView(
                    "No Publications",
                    systemImage: "newspaper",
                    description: Text("Publications you author will appear here.")
                )
                .readerClearListRow()
            } else {
                ForEach(publications) { publication in
                    Button {
                        onPublicationTap(publication)
                    } label: {
                        HStack(spacing: 12) {
                            PublicationAvatar(publication: publication, size: 42)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(publication.title)
                                    .font(.headline)
                                Text(publication.authorHandle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .readerFullWidthTapLabel()
                    }
                    .buttonStyle(.plain)
                    .readerClearListRow()
                    .contextMenu {
                        FolderAssignmentMenu(publication: publication)
                    }
                }
            }
        }
        .readerListCanvas()
    }
}
