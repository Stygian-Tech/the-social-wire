import SwiftUI

struct NewsSidebarView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    let availableTabs: [NewsTab]
    let sceneModel: NewsSceneModel
    @Binding var preferredCompactColumn: NavigationSplitViewColumn
    @State private var presentedSheet: NewsSidebarSheet?

    var body: some View {
        List {
            savedSection
            feedsSection
            librarySources
        }
        .listStyle(.sidebar)
        .listItemTint(.indigo)
        .navigationTitle("The Social Wire")
        .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
        .toolbar {
            if sceneModel.selectedTab == .library && appModel.readerListSource == .subscribed {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Add Publication", systemImage: "plus.circle") {
                            presentedSheet = .addPublication
                        }
                        Button("New Folder", systemImage: "folder.badge.plus") {
                            presentedSheet = .newFolder
                        }
                        Button("Import OPML", systemImage: "square.and.arrow.down") {
                            presentedSheet = .importOPML
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .help("Add a publication, folder, or OPML subscription list")
                }
            }
            if #available(macOS 26.0, iOS 26.0, *) {
                ToolbarItem(placement: .automatic) {
                    profileButton
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .automatic) {
                    profileButton
                }
            }
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .addPublication:
                AddPublicationView()
            case .newFolder:
                NewFolderView()
            case .importOPML:
                OPMLImportView()
            }
        }
    }

    private var feedsSection: some View {
        Section("Feeds") {
            if availableTabs.contains(.wire) {
                destinationRow(.wire)
            }
            if availableTabs.contains(.circle) {
                destinationRow(.circle)
            }
            sourceRow(.subscribed)
            sourceRow(.following)
        }
    }

    @ViewBuilder
    private var librarySources: some View {
        if sceneModel.selectedTab == .library {
            if appModel.selectedSidebar == .myPublications {
                authoredPublicationsSection
            } else {
                switch appModel.readerListSource {
                case .subscribed:
                    SubscribedPublicationSidebarTree(
                        showingNewFolder: sheetBinding(for: .newFolder),
                        showingAddPublication: sheetBinding(for: .addPublication),
                        onFolderTap: showDetail,
                        onPublicationTap: openPublication
                    )
                case .following:
                    FollowingPublicationSidebarTree(onPublicationTap: openPublication)
                case .wire, .readLater, .archive:
                    EmptyView()
                }
            }
        }
    }

    private var authoredPublicationsSection: some View {
        Section("Publications") {
            ForEach(appModel.myPublications) { publication in
                Button {
                    openPublication(publication)
                } label: {
                    HStack(spacing: 10) {
                        PublicationAvatar(publication: publication, size: 32)
                        Text(publication.title).lineLimit(1)
                    }
                    .readerFullWidthTapLabel()
                }
                .buttonStyle(.plain)
                .readerSidebarListRow()
            }
        }
    }

    private var savedSection: some View {
        Section("Saved") {
            sourceRow(.readLater)
            sourceRow(.archive)
        }
    }

    private func destinationRow(_ tab: NewsTab) -> some View {
        Button {
            select(tab)
        } label: {
            Label(tab.title, systemImage: tab.systemImage)
                .readerFullWidthTapLabel()
        }
        .buttonStyle(.plain)
        .readerSidebarListRow()
        .accessibilityIdentifier("news-tab-button-\(tab.rawValue)")
        .accessibilityAddTraits(sceneModel.selectedTab == tab ? .isSelected : [])
    }

    private func sourceRow(_ source: ReaderListSource) -> some View {
        let tab: NewsTab = source == .readLater || source == .archive ? .saved : .library
        return Button {
            appModel.selectReaderListSource(source)
            select(tab)
        } label: {
            Label(source.rawValue, systemImage: source.systemImage)
                .readerFullWidthTapLabel()
        }
        .buttonStyle(.plain)
        .readerSidebarListRow()
        .accessibilityAddTraits(
            sceneModel.selectedTab == tab && appModel.readerListSource == source ? .isSelected : []
        )
    }

    private func select(_ tab: NewsTab) {
        sceneModel.select(tab, availableTabs: availableTabs)
        sceneModel.resetPath(for: tab)
        preferredCompactColumn = .detail
    }

    private func openPublication(_ publication: DiscoveredPublication) {
        Task {
            await appModel.selectPublication(publication)
            guard appModel.selectedPublication?.publicationId == publication.publicationId else { return }
            showDetail()
        }
    }

    private func showDetail() {
        preferredCompactColumn = .detail
    }

    private var profileButton: some View {
        Button {
            sceneModel.navigate(to: .profile, in: sceneModel.selectedTab)
            preferredCompactColumn = .detail
        } label: {
            ViewerProfileAvatar(size: 30)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Profile")
    }

    private func sheetBinding(for sheet: NewsSidebarSheet) -> Binding<Bool> {
        Binding(
            get: { presentedSheet == sheet },
            set: { presentedSheet = $0 ? sheet : nil }
        )
    }

}

private enum NewsSidebarSheet: String, Identifiable {
    case addPublication
    case newFolder
    case importOPML

    var id: String { rawValue }
}
