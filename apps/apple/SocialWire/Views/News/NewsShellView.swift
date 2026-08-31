import SwiftUI

/// Adaptive application shell: bottom tabs on compact devices and a customizable sidebar on larger ones.
struct NewsShellView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @SceneStorage("the-social-wire.news-window-id.v1") private var windowID = UUID().uuidString
    @State private var sceneModel = NewsSceneModel()

    private var availableTabs: [NewsTab] {
        NewsTab.available(
            wire: appModel.wireCatalog?.isAvailable == true,
            circle: appModel.circleCatalog?.isAvailable == true
        )
    }

    private var selection: Binding<NewsTab> {
        Binding(
            get: { sceneModel.selectedTab },
            set: { sceneModel.select($0, availableTabs: availableTabs) }
        )
    }

    var body: some View {
        TabView(selection: selection) {
            if availableTabs.contains(.wire) {
                Tab(NewsTab.wire.title, systemImage: NewsTab.wire.systemImage, value: NewsTab.wire) {
                    tabStack(.wire) {
                        WireNewsView(sceneModel: sceneModel)
                    }
                }
            }

            if availableTabs.contains(.circle) {
                Tab(NewsTab.circle.title, systemImage: NewsTab.circle.systemImage, value: NewsTab.circle) {
                    tabStack(.circle) {
                        CircleNewsView(sceneModel: sceneModel)
                    }
                }
            }

            Tab(NewsTab.library.title, systemImage: NewsTab.library.systemImage, value: NewsTab.library) {
                tabStack(.library) {
                    LibraryNewsView(sceneModel: sceneModel)
                }
            }

            Tab(NewsTab.saved.title, systemImage: NewsTab.saved.systemImage, value: NewsTab.saved) {
                tabStack(.saved) {
                    SavedNewsView(sceneModel: sceneModel)
                }
            }

            Tab(NewsTab.search.title, systemImage: NewsTab.search.systemImage, value: NewsTab.search, role: .search) {
                tabStack(.search) {
                    PublicationSearchView()
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
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
            guard selection == .myPublications else { return }
            sceneModel.select(.library, availableTabs: availableTabs)
        }
    }

    private func pathBinding(for tab: NewsTab) -> Binding<[NewsRoute]> {
        Binding(
            get: { sceneModel.path(for: tab) },
            set: { sceneModel.setPath($0, for: tab) }
        )
    }

    private func tabStack<Content: View>(
        _ tab: NewsTab,
        @ViewBuilder content: () -> Content
    ) -> some View {
        NavigationStack(path: pathBinding(for: tab)) {
            content()
                .navigationDestination(for: NewsRoute.self) { route in
                    NewsRouteDestination(route: route, tab: tab, sceneModel: sceneModel)
                }
                .toolbar {
                    ToolbarItem(placement: .automatic) {
                        Button {
                            sceneModel.navigate(to: .profile, in: tab)
                        } label: {
                            ViewerProfileAvatar(size: 30)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Profile")
                    }
                }
        }
        .accessibilityIdentifier("news-tab-content-\(tab.rawValue)")
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
    }
}
