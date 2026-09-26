import SwiftUI

/// Adaptive application shell with configurable feed tabs, Read Later, and a leading-edge sidebar.
struct NewsShellView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @SceneStorage("the-social-wire.news-window-id.v1") private var windowID = UUID().uuidString
    @State private var sceneModel = NewsSceneModel()
    @State private var selectedSlot = NewsTabSlot.primaryOne
    @State private var lastPrimarySlot = NewsTabSlot.primaryOne
    @State private var slotFeeds: [NewsPrimaryFeed] = []
    @State private var transientPrimaryFeed: NewsPrimaryFeed?
    @State private var transientTransitionID = UUID()
    @State private var isTabConfigurationLoaded = false
    @State private var isProfilePresented = false

    private var availableTabs: [NewsTab] {
        NewsTab.available(
            preferences: appModel.feedPreferences,
            wireCatalog: appModel.wireCatalog,
            circleCatalog: appModel.circleCatalog
        )
    }

    private var activeNewsTab: NewsTab {
        selectedSlot.savedListSource != nil
            ? .saved
            : activePrimaryFeed?.newsTab ?? sceneModel.selectedTab
    }

    private var activePrimaryFeed: NewsPrimaryFeed? {
        if selectedSlot == .transient, let transientPrimaryFeed {
            return transientPrimaryFeed
        }
        let slot = selectedSlot.savedListSource == nil ? selectedSlot : lastPrimarySlot
        guard let index = slot.primaryIndex, slotFeeds.indices.contains(index) else {
            return slotFeeds.first
        }
        return slotFeeds[index]
    }

    /// LatrKit owns the archive; the Semble connector has no archived bucket to show.
    private var showsArchiveTab: Bool {
        !appModel.isSembleReadLaterEnabled
            && appModel.visibleReaderListSources.contains(.archive)
    }

    var body: some View {
        Group {
            if !isTabConfigurationLoaded {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                detailStack
            }
        }
        .task(bootstrap)
        .onChange(of: selectedSlot, selectedSlotChanged)
        .onChange(of: appModel.viewerDID, viewerDidChange)
        .onChange(of: appModel.primaryTabFeeds, primaryTabFeedsChanged)
        .onChange(of: appModel.feedPreferences) { _, _ in
            appModel.loadPrimaryTabPreferences()
            reconcileVisibleSelection()
        }
        .onChange(of: appModel.visiblePrimaryTabFeedChoices) { _, _ in
            appModel.loadPrimaryTabPreferences()
            reconcileVisibleSelection()
        }
        .onChange(of: appModel.feedSelection) { _, selection in
            if case .folder = selection { showSelectedLibraryScope() }
        }
        .onChange(of: showsArchiveTab) { _, showsArchive in
            if !showsArchive, selectedSlot == .archive { selectedSlot = .readLater }
        }
        .onChange(of: availableTabs, availableTabsChanged)
        .onChange(of: sceneModel.selectedTab, sceneTabChanged)
        .onChange(of: appModel.readerListSource, readerListSourceChanged)
        .onChange(of: appModel.selectedSidebar, sidebarSelectionChanged)
        .sheet(isPresented: $isProfilePresented) {
            NavigationStack {
                ProfileView()
            }
        }
    }

    private var detailStack: some View {
        feedTabs
        .accessibilityIdentifier("news-detail-column")
    }

    @ViewBuilder
    private var feedTabs: some View {
        #if os(iOS)
        // One size-class rule for every device: regular width (iPad, an unfolded iPhone Duo)
        // opens in the sidebar, compact width stays in the tab bar. macOS always has a sidebar,
        // so all three platforms land on the same layout.
        if #available(iOS 27.0, *) {
            feedTabsContent
                .defaultTabBarPlacement(preferredTabBarPlacement)
                .defaultAdaptableTabBarPlacement(preferredTabBarPlacement)
        } else {
            feedTabsContent
                .defaultAdaptableTabBarPlacement(preferredTabBarPlacement)
        }
        #else
        feedTabsContent
        #endif
    }

    #if os(iOS)
    private var preferredTabBarPlacement: AdaptableTabBarPlacement {
        horizontalSizeClass == .regular ? .sidebar : .tabBar
    }
    #endif

    private var feedTabsContent: some View {
        TabView(selection: $selectedSlot) {
            // Every destination stays at the top level. A TabSection would add a sidebar
            // title, but it also renders as one grouped entry in the iPadOS tab bar and
            // carries a collapse chevron that no API suppresses.
            ForEach(Array(NewsTabSlot.primarySlots.prefix(slotFeeds.count)), id: \.self) { slot in
                if let index = slot.primaryIndex, slotFeeds.indices.contains(index) {
                    let feed = slotFeeds[index]
                    Tab(
                        feed.title,
                        systemImage: feed.systemImage,
                        value: slot
                    ) {
                        if selectedSlot == slot {
                            NewsFeedShellView(
                                title: feed.title,
                                tab: feed.newsTab,
                                sceneModel: sceneModel,
                                isProfilePresented: $isProfilePresented,
                                supportsUnreadFilter: feed == .subscribed || feed == .following,
                                bulkReadScope: bulkReadScope(for: feed)
                            )
                        }
                    }
                }
            }

            if let transientPrimaryFeed {
                Tab(
                    transientPrimaryFeed.title,
                    systemImage: transientPrimaryFeed.systemImage,
                    value: NewsTabSlot.transient
                ) {
                    if selectedSlot == .transient {
                        NewsFeedShellView(
                            title: transientPrimaryFeed.title,
                            tab: transientPrimaryFeed.newsTab,
                            sceneModel: sceneModel,
                            isProfilePresented: $isProfilePresented,
                            supportsUnreadFilter: transientPrimaryFeed == .subscribed || transientPrimaryFeed == .following,
                            bulkReadScope: bulkReadScope(for: transientPrimaryFeed)
                        )
                    }
                }
            }

            savedTab(.readLater)
            if showsArchiveTab {
                savedTab(.archive)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabViewSidebarHeader {
            Text("The Social Wire")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("news-sidebar-column")
        }
    }

    private func savedTab(_ slot: NewsTabSlot) -> some TabContent<NewsTabSlot> {
        let source = slot.savedListSource ?? .readLater
        let title = source.rawValue
        return Tab(title, systemImage: source.systemImage, value: slot) {
            if selectedSlot == slot {
                NewsFeedShellView(
                    title: title,
                    tab: .saved,
                    sceneModel: sceneModel,
                    isProfilePresented: $isProfilePresented,
                    supportsUnreadFilter: false,
                    bulkReadScope: .unavailable
                )
            }
        }
    }

    private func bootstrap() async {
        sceneModel.configureWindow(identifier: windowID)
        if let viewerDID = appModel.viewerDID,
           let preferences = ReaderFeedPreferencesStorage.load(viewerDid: viewerDID) {
            appModel.feedPreferences = preferences
        }
        appModel.loadPrimaryTabPreferences()
        slotFeeds = appModel.primaryTabFeeds
        sceneModel.updateContext(viewerDID: appModel.viewerDID, availableTabs: availableTabs)

        if let viewerDID = appModel.viewerDID,
           let lastFeed = NewsPrimaryFeedStorage.lastFeed(viewerDID: viewerDID),
           slotFeeds.contains(lastFeed) {
            selectPrimaryFeed(lastFeed)
        } else if let firstFeed = slotFeeds.first {
            selectedSlot = .primaryOne
            activatePrimaryFeed(firstFeed)
        } else {
            selectedSlot = .readLater
            appModel.selectReaderListSource(.readLater)
            sceneModel.select(.saved, availableTabs: availableTabs)
        }
        isTabConfigurationLoaded = true
    }

    private func selectedSlotChanged(_ oldValue: NewsTabSlot, _ slot: NewsTabSlot) {
        if let source = slot.savedListSource {
            // Read Later and Archive are separate tabs now, so each owns its own source.
            appModel.selectReaderListSource(source)
            sceneModel.select(.saved, availableTabs: availableTabs)
        } else if slot == .transient {
            guard let transientPrimaryFeed else { return }
            activatePrimaryFeed(transientPrimaryFeed)
        } else {
            lastPrimarySlot = slot
            guard let activePrimaryFeed else { return }
            activatePrimaryFeed(activePrimaryFeed)
        }
        if oldValue == .transient, slot != .transient {
            removeTransientFeedAfterSelection()
        }
    }

    private func viewerDidChange(_ oldValue: String?, _ viewerDID: String?) {
        isTabConfigurationLoaded = false
        sceneModel.updateContext(viewerDID: viewerDID, availableTabs: availableTabs)
        appModel.loadPrimaryTabPreferences()
        slotFeeds = appModel.primaryTabFeeds
        transientPrimaryFeed = nil
        isTabConfigurationLoaded = true
    }

    private func primaryTabFeedsChanged(
        _ oldValue: [NewsPrimaryFeed],
        _ feeds: [NewsPrimaryFeed]
    ) {
        slotFeeds = Array(feeds.prefix(NewsTabSlot.primarySlots.count))

        if let transientPrimaryFeed,
           let index = slotFeeds.firstIndex(of: transientPrimaryFeed) {
            transientTransitionID = UUID()
            self.transientPrimaryFeed = nil
            selectedSlot = NewsTabSlot.primarySlots[index]
            lastPrimarySlot = selectedSlot
            activatePrimaryFeed(transientPrimaryFeed)
            return
        }

        if let index = selectedSlot.primaryIndex, !slotFeeds.indices.contains(index) {
            if feeds.isEmpty {
                selectedSlot = .readLater
            } else {
                selectedSlot = .primaryOne
                activatePrimaryFeed(feeds[0])
            }
        } else if selectedSlot.savedListSource == nil, let activePrimaryFeed {
            activatePrimaryFeed(activePrimaryFeed)
        }
    }

    private func availableTabsChanged(_ oldValue: [NewsTab], _ tabs: [NewsTab]) {
        sceneModel.updateContext(viewerDID: appModel.viewerDID, availableTabs: tabs)
    }

    private func sceneTabChanged(_ oldValue: NewsTab, _ tab: NewsTab) {
        guard isTabConfigurationLoaded else { return }
        switch tab {
        case .wire:
            selectPrimaryFeed(.wire)
        case .circle:
            selectPrimaryFeed(.circle)
        case .library:
            // A disappearing discovery tab can select Library before the reader source
            // has changed. Never turn that fallback into a hidden Wire tab.
            let preferred: NewsPrimaryFeed = appModel.readerListSource == .following ? .following : .subscribed
            let choices = appModel.visiblePrimaryTabFeedChoices
            if choices.contains(preferred) {
                selectPrimaryFeed(preferred)
            } else if let feed = choices.first(where: { $0 == .subscribed || $0 == .following }) {
                selectPrimaryFeed(feed)
            } else {
                selectedSlot = .readLater
            }
        case .saved:
            selectedSlot = appModel.readerListSource == .archive && showsArchiveTab
                ? .archive
                : .readLater
        case .search:
            break
        }
    }

    private func readerListSourceChanged(
        _ oldValue: ReaderListSource,
        _ source: ReaderListSource
    ) {
        guard isTabConfigurationLoaded,
              sceneModel.selectedTab == .library,
              let feed = primaryFeed(for: source)
        else { return }
        selectPrimaryFeed(feed)
    }

    private func sidebarSelectionChanged(_ oldValue: SidebarSelection?, _ selection: SidebarSelection?) {
        guard isTabConfigurationLoaded else { return }
        switch selection {
        case .publication:
            showSelectedLibraryScope()
        case .myPublications:
            selectPrimaryFeed(.subscribed)
            sceneModel.resetPath(for: .library)
        default:
            break
        }
    }

    private func showSelectedLibraryScope() {
        guard isTabConfigurationLoaded else { return }
        // Moving into Library must not invoke selectReaderListSource: that resets
        // the publication/folder which the sidebar or Profile just selected.
        let source: ReaderListSource = appModel.readerListSource == .following ? .following : .subscribed
        appModel.readerListSource = source
        appModel.publicationSidebarTab = source == .following ? .following : .subscribed
        ReaderListSourceStorage.save(source)
        selectPrimaryFeed(source == .following ? .following : .subscribed)
        sceneModel.resetPath(for: .library)
    }

    private func reconcileVisibleSelection() {
        guard isTabConfigurationLoaded else { return }
        if selectedSlot == .archive, !showsArchiveTab {
            selectedSlot = .readLater
        }
        if let transientPrimaryFeed,
           !appModel.visiblePrimaryTabFeedChoices.contains(transientPrimaryFeed) {
            self.transientPrimaryFeed = nil
            transientTransitionID = UUID()
            selectedSlot = slotFeeds.isEmpty ? .readLater : .primaryOne
        }
        // Reconcile even if the effective choices did not change the selected index.
        primaryTabFeedsChanged(slotFeeds, appModel.primaryTabFeeds)
    }

    private func selectPrimaryFeed(_ feed: NewsPrimaryFeed) {
        if let index = slotFeeds.firstIndex(of: feed) {
            selectedSlot = NewsTabSlot.primarySlots[index]
        } else {
            presentTransientFeed(feed)
            return
        }
        if selectedSlot.primaryIndex != nil {
            lastPrimarySlot = selectedSlot
        }
        activatePrimaryFeed(feed)
    }

    private func presentTransientFeed(_ feed: NewsPrimaryFeed) {
        guard transientPrimaryFeed != feed || selectedSlot != .transient else { return }
        let transitionID = UUID()
        transientTransitionID = transitionID

        withAnimation(.easeInOut(duration: 0.2)) {
            transientPrimaryFeed = feed
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            guard transientTransitionID == transitionID,
                  transientPrimaryFeed == feed else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedSlot = .transient
            }
            activatePrimaryFeed(feed)
        }
    }

    private func removeTransientFeedAfterSelection() {
        let transitionID = UUID()
        transientTransitionID = transitionID

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            guard transientTransitionID == transitionID,
                  selectedSlot != .transient else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                transientPrimaryFeed = nil
            }
        }
    }

    private func activatePrimaryFeed(_ feed: NewsPrimaryFeed) {
        if let source = feed.readerListSource,
           appModel.readerListSource != source {
            appModel.selectReaderListSource(source)
        }
        sceneModel.select(feed.newsTab, availableTabs: availableTabs)
        if let viewerDID = appModel.viewerDID {
            NewsPrimaryFeedStorage.saveLastFeed(feed, viewerDID: viewerDID)
        }
    }

    private func primaryFeed(for source: ReaderListSource) -> NewsPrimaryFeed? {
        switch source {
        case .wire:
            .wire
        case .subscribed:
            .subscribed
        case .following:
            .following
        case .readLater, .archive:
            nil
        }
    }

    private func bulkReadScope(for feed: NewsPrimaryFeed) -> ReaderMarkReadScope {
        switch feed {
        case .subscribed, .following:
            return ReaderMarkReadScope.selectedFeed(appModel.feedSelection)
        case .wire, .circle:
            return .unavailable
        }
    }
}

private struct NewsFeedShellView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @State private var presentedSheet: NewsShellSheet?

    let title: String
    let tab: NewsTab
    let sceneModel: NewsSceneModel
    @Binding var isProfilePresented: Bool
    let supportsUnreadFilter: Bool
    let bulkReadScope: ReaderMarkReadScope

    private enum NewsShellSheet: String, Identifiable {
        case addPublication
        case newFolder
        case importOPML

        var id: String { rawValue }
    }

    private var effectiveTitle: String {
        if tab == .library, let publication = appModel.selectedPublication {
            return publication.title
        }
        return title
    }

    var body: some View {
        NavigationStack(path: pathBinding) {
            NewsContentColumn(selectedTab: tab, sceneModel: sceneModel)
                .navigationTitle(effectiveTitle)
                .toolbar { toolbarContent }
                .navigationDestination(for: NewsRoute.self) { route in
                    NewsRouteDestination(route: route, tab: tab, sceneModel: sceneModel)
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

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: leadingPlacement) {
            Button {
                isProfilePresented = true
            } label: {
                ViewerProfileAvatar(size: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Profile")
        }
        if tab == .library && appModel.readerListSource == .subscribed {
            ToolbarItem(placement: trailingPlacement) {
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
        if supportsUnreadFilter {
            ToolbarItem(placement: trailingPlacement) {
                Button("Filter Unread", systemImage: unreadFilterSystemImage) {
                    Task {
                        await appModel.applyReaderFilter(appModel.readerFilter == .unread ? .all : .unread)
                    }
                }
                .accessibilityValue(appModel.readerFilter == .unread ? "On" : "Off")
            }
        }
        if bulkReadScope != .unavailable {
            ToolbarItem(placement: trailingPlacement) {
                FeedMarkReadButton(
                    contextID: "\(appModel.viewerDID ?? ""):news:\(bulkReadScope)",
                    refreshRevision: appModel.readAgeRevision,
                    scopeTitle: bulkReadTitle,
                    loadOptions: { onOptions in
                        try await appModel.readAgeOptions(for: bulkReadScope, onOptions: onOptions)
                    },
                    markAllRead: { await appModel.markRead(for: bulkReadScope) },
                    markOlderRead: { try await appModel.markRead(for: bulkReadScope, before: $0.before) },
                    markAllUnread: { await appModel.markUnread(for: bulkReadScope) }
                )
            }
        }
    }

    /// The bar placements differ by platform; macOS has no top bar edges.
    private var leadingPlacement: ToolbarItemPlacement {
        #if os(macOS)
        .navigation
        #else
        .topBarLeading
        #endif
    }

    private var trailingPlacement: ToolbarItemPlacement {
        #if os(macOS)
        .primaryAction
        #else
        .topBarTrailing
        #endif
    }

    private var pathBinding: Binding<[NewsRoute]> {
        Binding(
            get: { sceneModel.path(for: tab) },
            set: { sceneModel.setPath($0, for: tab) }
        )
    }

    private var unreadFilterSystemImage: String {
        appModel.readerFilter == .unread
            ? "line.3.horizontal.decrease.circle.fill"
            : "line.3.horizontal.decrease.circle"
    }

    private var bulkReadTitle: String {
        switch bulkReadScope {
        case .publication(let id):
            appModel.publication(forId: id)?.title ?? "This Publication"
        case .folder(let key):
            appModel.folders.first { $0.uri.hasSuffix("/\(key)") }?.value.name ?? "This Folder"
        default:
            effectiveTitle
        }
    }
}
