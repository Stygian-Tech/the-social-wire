import SwiftUI

/// Two-column application shell with navigation and sources in one sidebar.
struct NewsShellView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @SceneStorage("the-social-wire.news-window-id.v1") private var windowID = UUID().uuidString
    @State private var sceneModel = NewsSceneModel()
    @State private var preferredCompactColumn = NavigationSplitViewColumn.sidebar
    @State private var searchText = ""
    @State private var submittedSearch = ""

    private var availableTabs: [NewsTab] {
        NewsTab.available(
            wire: appModel.wireCatalog?.isAvailable == true,
            circle: true
        )
    }

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
            NewsSidebarView(
                availableTabs: availableTabs,
                sceneModel: sceneModel,
                preferredCompactColumn: $preferredCompactColumn
            )
        } detail: {
            detailStack
        }
        .navigationSplitViewStyle(.balanced)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Find Publications")
        .onSubmit(of: .search) {
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return }
            submittedSearch = query
            sceneModel.select(.search, availableTabs: availableTabs)
            sceneModel.resetPath(for: .search)
            preferredCompactColumn = .detail
        }
        .task {
            sceneModel.configureWindow(identifier: windowID)
            await appModel.refreshCircleCatalog()
            sceneModel.updateContext(viewerDID: appModel.viewerDID, availableTabs: availableTabs)
            configureAppModel(for: sceneModel.selectedTab)
        }
        .onChange(of: appModel.viewerDID) { _, viewerDID in
            sceneModel.updateContext(viewerDID: viewerDID, availableTabs: availableTabs)
        }
        .onChange(of: availableTabs) { _, tabs in
            sceneModel.updateContext(viewerDID: appModel.viewerDID, availableTabs: tabs)
        }
        .onChange(of: sceneModel.selectedTab) { _, tab in
            configureAppModel(for: tab)
        }
        .onChange(of: appModel.selectedSidebar) { _, selection in
            guard case .myPublications = selection else { return }
            sceneModel.select(.library, availableTabs: availableTabs)
        }
    }

    private var detailStack: some View {
        NavigationStack(path: pathBinding(for: sceneModel.selectedTab)) {
            detailContent
                .accessibilityIdentifier("news-tab-content-\(sceneModel.selectedTab.rawValue)")
                .navigationDestination(for: NewsRoute.self) { route in
                    NewsRouteDestination(route: route, tab: sceneModel.selectedTab, sceneModel: sceneModel)
                }
        }
        .id(sceneModel.selectedTab)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch sceneModel.selectedTab {
        case .wire:
            WireNewsView(sceneModel: sceneModel)
        case .circle:
            CircleNewsView(sceneModel: sceneModel)
        case .library:
            LibraryNewsView(sceneModel: sceneModel)
        case .saved:
            SavedNewsView(sceneModel: sceneModel)
        case .search:
            PublicationSearchView(query: submittedSearch)
        }
    }

    private func pathBinding(for tab: NewsTab) -> Binding<[NewsRoute]> {
        Binding(
            get: { sceneModel.path(for: tab) },
            set: { sceneModel.setPath($0, for: tab) }
        )
    }

    private func configureAppModel(for tab: NewsTab) {
        switch tab {
        case .wire:
            appModel.selectReaderListSource(.wire)
        case .circle, .search:
            break
        case .library:
            if appModel.selectedSidebar == .myPublications {
                return
            }
            if appModel.readerListSource != .subscribed && appModel.readerListSource != .following {
                appModel.selectReaderListSource(.subscribed)
            }
        case .saved:
            if appModel.readerListSource != .readLater && appModel.readerListSource != .archive {
                appModel.selectReaderListSource(.readLater)
            }
        }
    }
}

private struct NewsRouteDestination: View {
    @Environment(SocialWireAppModel.self) private var appModel
    let route: NewsRoute
    let tab: NewsTab
    let sceneModel: NewsSceneModel

    var body: some View {
        switch route {
        case .entry(let id):
            if let entry = appModel.selectedEntry, entry.entryId == id {
                EntryDetailView(entry: entry)
            } else {
                ContentUnavailableView("Article Unavailable", systemImage: "doc.text")
            }
        case .publication(let id):
            PublicationFeedRouteView(publicationID: id, tab: tab, sceneModel: sceneModel)
        case .savedLink(let id):
            if let save = appModel.selectedSavedLink, save.id == id {
                SavedLinkDetailView(save: save)
            } else {
                ContentUnavailableView("Saved Link Unavailable", systemImage: "bookmark.slash")
            }
        case .sembleItem(let id):
            if let item = appModel.selectedSembleItem, item.id == id {
                SembleItemDetailView(item: item)
            } else if let item = appModel.sembleItems.first(where: { $0.id == id }) {
                SembleItemDetailView(item: item)
            } else {
                ContentUnavailableView("Semble Card Unavailable", systemImage: "square.stack.3d.up.slash")
            }
        case .profile:
            ProfileView()
        case .settings:
            SettingsView(showsDoneButton: false)
        }
    }
}

private struct PublicationFeedRouteView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    let publicationID: String
    let tab: NewsTab
    let sceneModel: NewsSceneModel

    var body: some View {
        Group {
            if appModel.selectedPublication?.publicationId == publicationID {
                EntryListView(onEntryOpened: {
                    guard let entryID = appModel.selectedEntry?.entryId else { return }
                    sceneModel.navigate(to: .entry(id: entryID), in: tab)
                })
            } else if let publication = appModel.publication(forId: publicationID) {
                ProgressView()
                    .task(id: publicationID) {
                        await appModel.selectPublication(publication)
                    }
            } else {
                ContentUnavailableView("Publication Unavailable", systemImage: "newspaper")
            }
        }
        .navigationTitle(appModel.selectedPublication?.title ?? "Articles")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                let scope = ReaderMarkReadScope.publication(publicationId: publicationID)
                FeedMarkReadButton(
                    contextID: "\(appModel.viewerDID ?? ""):publication:\(publicationID)",
                    refreshRevision: appModel.readAgeRevision,
                    scopeTitle: appModel.selectedPublication?.title ?? "This Feed",
                    loadOptions: { try await appModel.readAgeOptions(for: scope) },
                    markAllRead: { await appModel.markRead(for: scope) },
                    markOlderRead: { try await appModel.markRead(for: scope, before: $0.before) },
                    markAllUnread: { await appModel.markUnread(for: scope) }
                )
            }
        }
    }
}
