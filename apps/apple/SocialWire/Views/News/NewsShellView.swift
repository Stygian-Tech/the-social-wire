import SwiftUI

/// Adaptive application shell with configurable feed tabs, Read Later, and a leading-edge sidebar.
struct NewsShellView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @SceneStorage("the-social-wire.news-window-id.v1") private var windowID = UUID().uuidString
    @State private var sceneModel = NewsSceneModel()
    @State private var selectedSlot = NewsTabSlot.wire
    @State private var selectedSection = NewsRootSection.feeds
    @State private var sectionSelections: [NewsRootSection: NewsTabSlot] = [
        .readLater: .readLater,
        .feeds: .wire,
        .topics: .finance
    ]
    @State private var slotFeeds: [NewsPrimaryFeed] = []
    @State private var isTabConfigurationLoaded = false
    @State private var isProfilePresented = false
    #if os(iOS)
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    #endif

    private var availableTabs: [NewsTab] {
        NewsTab.available(
            wire: appModel.feedPreferences.showWire,
            circle: appModel.feedPreferences.showCircle,
            finance: appModel.feedPreferences.showFinance,
            sports: appModel.feedPreferences.showSports,
            podcasts: false
        )
    }

    private var activeNewsTab: NewsTab {
        selectedSlot.savedListSource != nil
            ? .saved
            : activePrimaryFeed?.newsTab ?? sceneModel.selectedTab
    }

    private var activePrimaryFeed: NewsPrimaryFeed? {
        selectedSlot.primaryFeed
    }

    private var navigableFeeds: [NewsPrimaryFeed] {
        let available = appModel.visiblePrimaryTabFeedChoices
        return (slotFeeds + available.filter { !slotFeeds.contains($0) })
            .filter { $0 != .podcasts }
    }

    private var feedDestinations: [NewsPrimaryFeed] {
        [.wire, .circle, .subscribed, .following].filter(isVisibleInSettings)
    }

    private var topicDestinations: [NewsPrimaryFeed] {
        [.finance, .sports].filter(isVisibleInSettings)
    }

    private func isVisibleInSettings(_ feed: NewsPrimaryFeed) -> Bool {
        switch feed {
        case .wire:
            appModel.feedPreferences.showWire
        case .circle:
            appModel.feedPreferences.showCircle
        case .finance:
            appModel.feedPreferences.showFinance
        case .sports:
            appModel.feedPreferences.showSports
        case .subscribed:
            appModel.feedPreferences.visibleFeeds.contains(.subscribed)
        case .following:
            appModel.feedPreferences.visibleFeeds.contains(.following)
        case .podcasts:
            false
        }
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
        .task(id: NewsDestinationLoadContext(viewerDID: appModel.viewerDID, slot: selectedSlot)) {
            await loadSelectedDestination(selectedSlot)
        }
        .onChange(of: selectedSlot, selectedSlotChanged)
        .onChange(of: selectedSection, selectedSectionChanged)
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
        Group {
            #if os(iOS)
            if horizontalSizeClass == .regular {
                regularWidthSplitView
            } else {
                feedTabs
            }
            #else
            feedTabs
            #endif
        }
        .accessibilityIdentifier("news-detail-column")
    }

    #if os(iOS)
    private var regularWidthSplitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            NewsSidebarView(
                availableTabs: availableTabs,
                sceneModel: sceneModel,
                onSelection: {},
                onStandardListSelection: { list in
                    selectedSection = .lists
                    Task { await appModel.standardReaderLists.select(list) }
                }
            )
        } detail: {
            if selectedSection == .lists {
                listsWorkspace
            } else {
                destinationContent(
                    for: selectedSlot,
                    navigationItems: navigationItems(for: selectedSection),
                    selection: sectionSelectionBinding(for: selectedSection),
                    usesSidebarNavigation: true
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
    #endif

    @ViewBuilder
    private var feedTabs: some View {
        feedTabsContent
            .tabViewStyle(.sidebarAdaptable)
    }

    private var readLaterNavigationItems: [NewsNavigationItem] {
        [NewsNavigationItem(slot: .readLater, title: "Read Later", systemImage: "bookmark")]
            + (showsArchiveTab ? [NewsNavigationItem(slot: .archive, title: "Archive", systemImage: "archivebox")] : [])
    }

    private var standardListNavigationItems: [NewsNavigationItem] {
        appModel.standardReaderLists.lists.map {
            NewsNavigationItem(slot: .standardList($0.uri), title: $0.name, systemImage: "list.bullet")
        }
    }

    @ViewBuilder
    private func destinationContent(
        for slot: NewsTabSlot,
        navigationItems: [NewsNavigationItem],
        selection: Binding<NewsTabSlot>,
        usesSidebarNavigation: Bool = false
    ) -> some View {
        if let source = slot.savedListSource {
            destinationView(
                title: source.rawValue,
                tab: .saved,
                navigationItems: navigationItems,
                selection: selection,
                supportsUnreadFilter: false,
                bulkReadScope: .unavailable,
                usesSidebarNavigation: usesSidebarNavigation
            )
        } else if case .standardList(let uri) = slot,
                  let list = appModel.standardReaderLists.lists.first(where: { $0.uri == uri }) {
            destinationView(
                title: list.name,
                tab: .library,
                navigationItems: navigationItems,
                selection: selection,
                supportsUnreadFilter: false,
                bulkReadScope: .unavailable,
                usesSidebarNavigation: usesSidebarNavigation
            )
        } else if let feed = selectedSlot.primaryFeed {
            destinationView(
                title: feed.title,
                tab: feed.newsTab,
                navigationItems: navigationItems,
                selection: selection,
                supportsUnreadFilter: feed == .subscribed || feed == .following,
                bulkReadScope: bulkReadScope(for: feed),
                usesSidebarNavigation: usesSidebarNavigation
            )
        }
    }

    private func destinationView(
        title: String,
        tab: NewsTab,
        navigationItems: [NewsNavigationItem],
        selection: Binding<NewsTabSlot>,
        supportsUnreadFilter: Bool,
        bulkReadScope: ReaderMarkReadScope,
        usesSidebarNavigation: Bool = false
    ) -> some View {
        NewsFeedShellView(
            title: title,
            tab: tab,
            sceneModel: sceneModel,
            isProfilePresented: $isProfilePresented,
            navigationItems: navigationItems,
            selection: selection,
            supportsUnreadFilter: supportsUnreadFilter,
            bulkReadScope: bulkReadScope,
            usesSidebarNavigation: usesSidebarNavigation
        )
    }

    private var feedTabsContent: some View {
        TabView(selection: $selectedSection) {
            Tab("Read Later", systemImage: "bookmark", value: NewsRootSection.readLater) {
                sectionPager(.readLater, items: readLaterNavigationItems)
            }
            Tab("Feeds", systemImage: "newspaper", value: NewsRootSection.feeds) {
                sectionPager(.feeds, items: feedDestinations.map(NewsNavigationItem.init(feed:)))
            }
            Tab("Topics", systemImage: "square.grid.2x2", value: NewsRootSection.topics) {
                sectionPager(.topics, items: topicDestinations.map(NewsNavigationItem.init(feed:)))
            }
            Tab("Lists", systemImage: "list.bullet", value: NewsRootSection.lists) {
                listsWorkspace
            }
        }
    }

    private var listsWorkspace: some View {
        StandardReaderListsWorkspace()
            .accessibilityIdentifier("news-tab-content-standardLists")
    }

    private func sectionPager(_ section: NewsRootSection, items: [NewsNavigationItem]) -> some View {
        let selection = sectionSelectionBinding(for: section)
        return NewsSectionPager(items: items, selection: selection) { slot in
            destinationContent(for: slot, navigationItems: items, selection: selection)
        } emptyContent: {
            ContentUnavailableView(
                section.emptyTitle,
                systemImage: section.systemImage,
                description: Text(section.emptyDescription)
            )
        }
    }

    private func sectionSelectionBinding(for section: NewsRootSection) -> Binding<NewsTabSlot> {
        Binding(
            get: {
                let items = navigationItems(for: section)
                if let remembered = sectionSelections[section], items.contains(where: { $0.slot == remembered }) {
                    return remembered
                }
                return items.first?.slot ?? section.fallbackSlot
            },
            set: { slot in
                sectionSelections[section] = slot
                if selectedSection == section {
                    selectedSlot = slot
                }
            }
        )
    }

    private func navigationItems(for section: NewsRootSection) -> [NewsNavigationItem] {
        switch section {
        case .readLater:
            readLaterNavigationItems
        case .feeds:
            feedDestinations.map(NewsNavigationItem.init(feed:))
        case .topics:
            topicDestinations.map(NewsNavigationItem.init(feed:))
        case .lists:
            standardListNavigationItems
        }
    }

    private func selectedSectionChanged(_ oldValue: NewsRootSection, _ section: NewsRootSection) {
        guard section != .lists else { return }
        reconcileSectionSelection(section)
    }

    private func reconcileSectionSelection(_ section: NewsRootSection) {
        let items = navigationItems(for: section)
        guard let slot = sectionSelections[section].flatMap({ remembered in
            items.first(where: { $0.slot == remembered })?.slot
        }) ?? items.first?.slot else { return }
        sectionSelections[section] = slot
        if selectedSection == section, selectedSlot != slot {
            selectedSlot = slot
        }
    }

    private func bootstrap() async {
        sceneModel.configureWindow(identifier: windowID)
        if let viewerDID = appModel.viewerDID,
           let preferences = ReaderFeedPreferencesStorage.load(viewerDid: viewerDID) {
            appModel.feedPreferences = preferences
        }
        appModel.loadPrimaryTabPreferences()
        slotFeeds = appModel.primaryTabFeeds.filter { $0 != .podcasts }
        sceneModel.updateContext(viewerDID: appModel.viewerDID, availableTabs: availableTabs)

        if let viewerDID = appModel.viewerDID,
           let lastFeed = NewsPrimaryFeedStorage.lastFeed(viewerDID: viewerDID),
           slotFeeds.contains(lastFeed) {
            selectPrimaryFeed(lastFeed)
        } else if let firstFeed = slotFeeds.first {
            selectedSlot = NewsTabSlot(firstFeed)
            activatePrimaryFeed(firstFeed)
        } else {
            selectedSlot = .readLater
            sceneModel.prepareForReaderSourceChange(from: appModel.readerListSource, to: .readLater)
            appModel.selectReaderListSource(.readLater)
            sceneModel.select(.saved, availableTabs: availableTabs)
        }
        isTabConfigurationLoaded = true
    }

    private func selectedSlotChanged(_ oldValue: NewsTabSlot, _ slot: NewsTabSlot) {
        if let section = rootSection(for: slot) {
            sectionSelections[section] = slot
            if selectedSection != section {
                selectedSection = section
            }
        }
        if let source = slot.savedListSource {
            // Read Later and Archive are separate tabs now, so each owns its own source.
            sceneModel.prepareForReaderSourceChange(from: appModel.readerListSource, to: source)
            appModel.selectReaderListSource(source)
            sceneModel.select(.saved, availableTabs: availableTabs)
        } else if case let .standardList(uri) = slot,
                  let list = appModel.standardReaderLists.lists.first(where: { $0.uri == uri }) {
            Task { await appModel.standardReaderLists.select(list) }
        } else if let feed = slot.primaryFeed {
            activatePrimaryFeed(feed)
        }
    }

    private func loadSelectedDestination(_ slot: NewsTabSlot) async {
        guard let feed = slot.primaryFeed else { return }
        switch feed {
        case .wire:
            if appModel.wireCatalog == nil {
                await appModel.refreshWireCatalog()
            }
            await appModel.loadWireEdition()
        case .circle:
            if appModel.circleCatalog == nil {
                await appModel.refreshCircleCatalog()
            }
            await appModel.loadCircleEdition()
        case .finance:
            async let feeds: Void = appModel.loadFinanceFeeds()
            async let customization: Void = appModel.loadFinanceCustomization()
            async let stories: Void = appModel.loadFinance()
            _ = await (feeds, customization, stories)
        case .sports:
            let topic = appModel.sportsTopic
            topic.bind(viewer: appModel.viewerDID)
            await topic.loadCatalog()
            async let stories: Void = topic.load(language: Locale.current.language.languageCode?.identifier ?? "en")
            async let events: Void = topic.loadEvents()
            _ = await (stories, events)
        case .subscribed, .following, .podcasts:
            break
        }
    }

    private func rootSection(for slot: NewsTabSlot) -> NewsRootSection? {
        if slot.savedListSource != nil { return .readLater }
        if case .standardList = slot { return .lists }
        guard let feed = slot.primaryFeed else { return nil }
        return [.finance, .sports].contains(feed) ? .topics : .feeds
    }

    private func viewerDidChange(_ oldValue: String?, _ viewerDID: String?) {
        isTabConfigurationLoaded = false
        sceneModel.updateContext(viewerDID: viewerDID, availableTabs: availableTabs)
        appModel.loadPrimaryTabPreferences()
        slotFeeds = appModel.primaryTabFeeds.filter { $0 != .podcasts }
        isTabConfigurationLoaded = true
    }

    private func primaryTabFeedsChanged(
        _ oldValue: [NewsPrimaryFeed],
        _ feeds: [NewsPrimaryFeed]
    ) {
        slotFeeds = feeds.filter { $0 != .podcasts }

        if let selectedFeed = selectedSlot.primaryFeed,
           !appModel.visiblePrimaryTabFeedChoices.contains(selectedFeed) {
            if let firstFeed = navigableFeeds.first {
                selectPrimaryFeed(firstFeed)
            } else {
                selectedSlot = .readLater
            }
        } else if let activePrimaryFeed {
            activatePrimaryFeed(activePrimaryFeed)
        }
    }

    private func availableTabsChanged(_ oldValue: [NewsTab], _ tabs: [NewsTab]) {
        sceneModel.updateContext(viewerDID: appModel.viewerDID, availableTabs: tabs)
    }

    private func sceneTabChanged(_ oldValue: NewsTab, _ tab: NewsTab) {
        guard isTabConfigurationLoaded, selectedSection != .lists else { return }
        switch tab {
        case .wire:
            selectPrimaryFeed(.wire)
        case .finance:
            selectPrimaryFeed(.finance)
        case .podcasts:
            selectPrimaryFeed(.podcasts)
        case .sports:
            selectPrimaryFeed(.sports)
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
              selectedSection != .lists,
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
        primaryTabFeedsChanged(slotFeeds, appModel.primaryTabFeeds)
    }

    private func selectPrimaryFeed(_ feed: NewsPrimaryFeed) {
        selectedSlot = NewsTabSlot(feed)
        activatePrimaryFeed(feed)
    }

    private func activatePrimaryFeed(_ feed: NewsPrimaryFeed) {
        if let source = feed.readerListSource,
           appModel.readerListSource != source {
            sceneModel.prepareForReaderSourceChange(from: appModel.readerListSource, to: source)
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
        case .wire, .circle, .finance, .sports, .podcasts:
            return .unavailable
        }
    }
}

private struct NewsFeedShellView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.openURL) private var openURL
    @State private var presentedSheet: NewsShellSheet?
    @State private var suppressesContentTaps = false
    @State private var tapGateReleaseTask: Task<Void, Never>?
    @GestureState private var horizontalDragOffset: CGFloat = 0
    @GestureState private var isSectionSwiping = false

    let title: String
    let tab: NewsTab
    let sceneModel: NewsSceneModel
    @Binding var isProfilePresented: Bool
    let navigationItems: [NewsNavigationItem]
    @Binding var selection: NewsTabSlot
    let supportsUnreadFilter: Bool
    let bulkReadScope: ReaderMarkReadScope
    let usesSidebarNavigation: Bool

    private enum NewsShellSheet: String, Identifiable {
        case addPublication
        case newFolder
        case importOPML

        var id: String { rawValue }
    }

    private var effectiveTitle: String {
        if tab == .finance {
            return appModel.selectedFinanceFeed.title
        }
        if tab == .sports {
            return appModel.sportsTopic.selectedTitle
        }
        if tab == .library, let publication = appModel.selectedPublication {
            return publication.title
        }
        return title
    }

    var body: some View {
        NavigationStack(path: pathBinding) {
            ZStack {
                NewsContentColumn(selectedTab: tab, sceneModel: sceneModel)
                    .environment(
                        \.suppressesNewsContentActions,
                        isSectionSwiping || suppressesContentTaps
                    )
                    .environment(\.openURL, guardedOpenURLAction)
                    .allowsHitTesting(!isSectionSwiping && !suppressesContentTaps)
                    .offset(x: horizontalDragOffset)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(usesSidebarNavigation ? nil : sectionSwipeGesture)
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
        ToolbarItem(placement: .principal) {
            if usesSidebarNavigation {
                Text(effectiveTitle)
                    .font(.headline)
            } else {
                NewsHorizontalNavigationBar(items: navigationItems, selection: $selection)
            }
        }
        if !usesSidebarNavigation {
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

    private var sectionSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                tapGateReleaseTask?.cancel()
                suppressesContentTaps = true
            }
            .updating($horizontalDragOffset) { value, offset, _ in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                offset = value.translation.width
            }
            .updating($isSectionSwiping) { value, isSwiping, _ in
                isSwiping = abs(value.translation.width) > abs(value.translation.height)
            }
            .onEnded { value in
                releaseTapGateAfterSwipe()
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let projectedWidth = value.predictedEndTranslation.width
                let distance = abs(projectedWidth) > abs(value.translation.width)
                    ? projectedWidth
                    : value.translation.width
                guard abs(distance) >= 60,
                      let currentIndex = navigationItems.firstIndex(where: { $0.slot == selection })
                else { return }

                let destinationIndex = distance < 0 ? currentIndex + 1 : currentIndex - 1
                guard navigationItems.indices.contains(destinationIndex) else { return }
                withAnimation(.snappy) {
                    selection = navigationItems[destinationIndex].slot
                }
            }
    }

    private var guardedOpenURLAction: OpenURLAction {
        OpenURLAction { url in
            guard !isSectionSwiping, !suppressesContentTaps else { return .discarded }
            openURL(url)
            return .handled
        }
    }

    private func releaseTapGateAfterSwipe() {
        tapGateReleaseTask?.cancel()
        tapGateReleaseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            suppressesContentTaps = false
        }
    }
}

private enum NewsRootSection: String, Hashable {
    case readLater
    case feeds
    case topics
    case lists

    var systemImage: String {
        switch self {
        case .readLater: "bookmark"
        case .feeds: "newspaper"
        case .topics: "square.grid.2x2"
        case .lists: "list.bullet"
        }
    }

    var fallbackSlot: NewsTabSlot {
        switch self {
        case .readLater: .readLater
        case .feeds: .wire
        case .topics: .finance
        case .lists: .standardList("")
        }
    }

    var emptyTitle: LocalizedStringResource {
        switch self {
        case .readLater: "Nothing Saved"
        case .feeds: "No Feeds"
        case .topics: "No Topics"
        case .lists: "No Lists"
        }
    }

    var emptyDescription: LocalizedStringResource {
        switch self {
        case .readLater: "Saved articles will appear here."
        case .feeds: "Available feeds will appear here."
        case .topics: "Available topics will appear here."
        case .lists: "Your reader lists will appear here."
        }
    }
}

private struct NewsDestinationLoadContext: Equatable {
    let viewerDID: String?
    let slot: NewsTabSlot
}

private struct NewsSectionPager<Content: View, EmptyContent: View>: View {
    let items: [NewsNavigationItem]
    @Binding var selection: NewsTabSlot
    @ViewBuilder let content: (NewsTabSlot) -> Content
    @ViewBuilder let emptyContent: () -> EmptyContent
    var body: some View {
        if items.isEmpty {
            emptyContent()
        } else {
            content(selection)
        }
    }
}

private struct NewsNavigationItem: Identifiable, Hashable {
    let slot: NewsTabSlot
    let title: String
    let systemImage: String

    var id: NewsTabSlot { slot }

    init(slot: NewsTabSlot, title: String, systemImage: String) {
        self.slot = slot
        self.title = title
        self.systemImage = systemImage
    }

    init(feed: NewsPrimaryFeed) {
        slot = NewsTabSlot(feed)
        title = feed.title
        systemImage = feed.systemImage
    }
}

private struct NewsHorizontalNavigationBar: View {
    let items: [NewsNavigationItem]
    @Binding var selection: NewsTabSlot

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(items) { item in
                        Button {
                            selection = item.slot
                        } label: {
                            Label(item.title, systemImage: item.systemImage)
                                .font(.subheadline.weight(selection == item.slot ? .semibold : .regular))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(
                                    selection == item.slot
                                        ? AnyShapeStyle(Color.accentColor.opacity(0.18))
                                        : AnyShapeStyle(.thinMaterial),
                                    in: .capsule
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selection == item.slot ? .isSelected : [])
                        .id(item.slot)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .scrollIndicators(.hidden)
            .onAppear { scrollToSelection(using: proxy, animated: false) }
            .onChange(of: selection) { _, _ in
                scrollToSelection(using: proxy, animated: true)
            }
            .onChange(of: items) { _, _ in
                scrollToSelection(using: proxy, animated: false)
            }
        }
    }

    private func scrollToSelection(using proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.snappy) {
                proxy.scrollTo(selection, anchor: .center)
            }
        } else {
            proxy.scrollTo(selection, anchor: .center)
        }
    }
}
