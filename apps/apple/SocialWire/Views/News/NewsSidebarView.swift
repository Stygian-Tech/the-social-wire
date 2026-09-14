import SwiftUI

struct NewsSidebarView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    let availableTabs: [NewsTab]
    let sceneModel: NewsSceneModel
    let onSelection: () -> Void
    @State private var presentedSheet: NewsSidebarSheet?
    @State private var isReadLaterExpanded = false

    var body: some View {
        List {
            savedSection
            feedsSection
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
            case .profile:
                NavigationStack {
                    ProfileView()
                }
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
        @Bindable var model = appModel

        return Section("Feeds") {
            if availableTabs.contains(.wire) {
                destinationRow(.wire)
            }
            if availableTabs.contains(.circle) {
                destinationRow(.circle)
            }
            if appModel.visibleReaderListSources.contains(.subscribed) {
                DisclosureGroup(isExpanded: $model.sidebarSubscribedFeedExpanded) {
                    SubscribedPublicationSidebarTree(
                        showingNewFolder: sheetBinding(for: .newFolder),
                        showingAddPublication: sheetBinding(for: .addPublication),
                        onFolderTap: showContent,
                        onPublicationTap: openPublication
                    )
                } label: {
                    sourceHierarchyLabel(.subscribed)
                }
                .readerSidebarListRow()
                .onChange(of: model.sidebarSubscribedFeedExpanded) { _, _ in
                    appModel.noteSidebarExpandedPresentationChanged()
                }
            }

            if appModel.visibleReaderListSources.contains(.following) {
                DisclosureGroup(isExpanded: $model.sidebarFollowingFeedExpanded) {
                    FollowingPublicationSidebarTree(onPublicationTap: openPublication)
                } label: {
                    sourceHierarchyLabel(.following)
                }
                .readerSidebarListRow()
                .onChange(of: model.sidebarFollowingFeedExpanded) { _, _ in
                    appModel.noteSidebarExpandedPresentationChanged()
                }
            }
        }
    }

    private var savedSection: some View {
        Section("Saved") {
            DisclosureGroup(isExpanded: $isReadLaterExpanded) {
                if !appModel.currentSavedFeedSources.isEmpty {
                    Button {
                        appModel.clearSavedFeedSource()
                        selectSavedSource()
                    } label: {
                        FeedSidebarRowLabel(
                            title: "All Saved Stories",
                            systemImage: "tray.full",
                            unreadCount: appModel.currentSavedLinks.count
                        )
                    }
                    .buttonStyle(.plain)
                    .readerSidebarListRow()

                    ForEach(appModel.currentSavedFeedSources) { source in
                        Button {
                            appModel.selectSavedFeedSource(source)
                            selectSavedSource()
                        } label: {
                            HStack(spacing: 8) {
                                SavedLinkPublicationChip(model: source.model)
                                Spacer(minLength: 8)
                                SidebarCountLabel(
                                    count: source.count,
                                    accessibilityDescription: "saved articles"
                                )
                            }
                            .readerFullWidthTapLabel()
                        }
                        .buttonStyle(.plain)
                        .readerSidebarListRow()
                    }
                }
            } label: {
                Button {
                    appModel.clearSavedFeedSource()
                    selectSavedSource()
                } label: {
                    FeedSidebarRowLabel(
                        title: ReaderListSource.readLater.rawValue,
                        systemImage: ReaderListSource.readLater.systemImage,
                        unreadCount: nil
                    )
                }
                .buttonStyle(.plain)
            }
            .readerSidebarListRow()
            if appModel.visibleReaderListSources.contains(.archive) {
                sourceRow(.archive)
            }
        }
    }

    private func selectSavedSource() {
        appModel.selectReaderListSource(.readLater)
        select(.saved)
    }

    private func destinationRow(_ tab: NewsTab) -> some View {
        Button {
            select(tab)
        } label: {
            FeedSidebarRowLabel(
                title: tab.title,
                systemImage: tab.systemImage,
                unreadCount: nil
            )
        }
        .buttonStyle(.plain)
        .readerSidebarListRow()
        .accessibilityIdentifier("news-tab-button-\(tab.rawValue)")
        .accessibilityAddTraits(sceneModel.selectedTab == tab ? .isSelected : [])
    }

    private func sourceHierarchyLabel(_ source: ReaderListSource) -> some View {
        Button {
            appModel.selectReaderListSource(source)
            select(.library)
        } label: {
            FeedSidebarRowLabel(
                title: source.rawValue,
                systemImage: source.systemImage,
                unreadCount: displayedUnreadCount(for: source)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(
            sceneModel.selectedTab == .library && appModel.readerListSource == source ? .isSelected : []
        )
    }

    private func sourceRow(_ source: ReaderListSource) -> some View {
        let tab: NewsTab = source == .readLater || source == .archive ? .saved : .library
        return Button {
            appModel.selectReaderListSource(source)
            select(tab)
        } label: {
            FeedSidebarRowLabel(
                title: source.rawValue,
                systemImage: source.systemImage,
                unreadCount: displayedUnreadCount(for: source)
            )
        }
        .buttonStyle(.plain)
        .readerSidebarListRow()
        .accessibilityAddTraits(
            sceneModel.selectedTab == tab && appModel.readerListSource == source ? .isSelected : []
        )
    }

    private func select(_ tab: NewsTab) {
        sceneModel.select(tab, availableTabs: availableTabs)
        onSelection()
    }

    private func openPublication(_ publication: DiscoveredPublication) {
        Task {
            await appModel.selectPublication(publication)
            guard appModel.selectedPublication?.publicationId == publication.publicationId else { return }
            sceneModel.resetPath(for: .library)
            showContent()
        }
    }

    private func showContent() {
        onSelection()
    }

    private func displayedUnreadCount(for source: ReaderListSource) -> Int? {
        guard appModel.showsTopLevelFeedUnreadCount(for: source) else { return nil }
        return appModel.topLevelUnreadCount(for: source)
    }

    private var profileButton: some View {
        Button {
            presentedSheet = .profile
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
    case profile
    case addPublication
    case newFolder
    case importOPML

    var id: String { rawValue }
}
