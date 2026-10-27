import SwiftUI

/// Adaptive application shell with configurable feed tabs, Read Later, and a leading-edge sidebar.
struct NewsShellView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    #endif
    @SceneStorage("the-social-wire.news-window-id.v1") private var windowID = UUID().uuidString
    @State private var sceneModel = NewsSceneModel()
    @State private var selectedSlot = NewsTabSlot.wire
    @State private var selectedSection = NewsRootSection.feeds
    @State private var selectedSocialDestination = SocialDestination.timeline
    @State private var socialNavigation = SocialNavigationState()
    @State private var isBrowsing = false
    @State private var sectionSelections: [NewsRootSection: NewsTabSlot] = [
        .readLater: .readLater,
        .feeds: .wire,
        .topics: .finance,
        .media: .podcasts,
        .social: .wire
    ]
    @State private var slotFeeds: [NewsPrimaryFeed] = []
    @State private var isTabConfigurationLoaded = false
    @State private var isProfilePresented = false
    @State private var isSidebarPresented = false
    @State private var isPersistentSidebarPresented = true
    @State private var isCustomizationPresented = false
    @State private var sectionPreferences = NewsSectionPreferences()
    #if os(iOS)
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var compactColumn = NavigationSplitViewColumn.detail

    private var usesPhoneTabs: Bool { UIDevice.current.userInterfaceIdiom != .pad }
    #endif

    private var availableTabs: [NewsTab] {
        NewsTab.available(
            wire: appModel.feedPreferences.showWire,
            circle: appModel.feedPreferences.showCircle,
            finance: appModel.feedPreferences.showFinance,
            sports: appModel.feedPreferences.showSports,
            podcasts: appModel.feedPreferences.showPodcasts && appModel.podcasts.available
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
        return slotFeeds + available.filter { !slotFeeds.contains($0) }
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
            appModel.feedPreferences.showPodcasts && appModel.podcasts.available
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
        #if os(iOS)
        .onChange(of: horizontalSizeClass) { _, sizeClass in
            if sizeClass == .regular { isSidebarPresented = false }
        }
        .task(id: NewsSocialBadgeContext(viewerDID: appModel.viewerDID,
                                        modelIdentity: appModel.social.quill.map(ObjectIdentifier.init),
                                        scenePhase: scenePhase)) {
            guard scenePhase == .active, let social = appModel.social.quill else { return }
            while !Task.isCancelled {
                await social.refreshNotificationBadge()
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
        #endif
        .task(bootstrap)
        .onChange(of: sectionPreferences) { _, preferences in
            preferences.save(viewerDID: appModel.viewerDID)
        }
        .sheet(isPresented: $isCustomizationPresented) {
            NewsSectionCustomizationView(preferences: $sectionPreferences)
        }
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
            adaptiveWorkspace
            #else
            feedTabs
            #endif
        }
        #if os(macOS)
        .accessibilityIdentifier("news-detail-column")
        #endif
    }

    #if os(iOS)
    @ViewBuilder
    private var adaptiveWorkspace: some View {
        if usesPhoneTabs {
            phoneWorkspace
        } else {
            sectionWorkspace(selectedSection)
        }
    }

    private var phoneWorkspace: some View {
        NewsCompactSidebarContainer(isSidebarPresented: $isSidebarPresented) {
            navigationSidebar
                .navigationTitle("The Social Wire")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close Sidebar", systemImage: "sidebar.left") {
                            isSidebarPresented = false
                        }
                        .accessibilityIdentifier("news-hide-sidebar")
                    }
                }
        } content: {
            HStack(spacing: 0) {
                if horizontalSizeClass == .regular && isPersistentSidebarPresented {
                    NavigationStack {
                        navigationSidebar
                            // The sidebar is an internal column, away from the trailing system bar.
                            .ignoresSafeArea(.container, edges: .trailing)
                            .navigationTitle("The Social Wire")
                    }
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 320)
                    .accessibilityIdentifier("news-persistent-sidebar")
                    Divider()
                }
                phoneTabs
            }
        }
    }

    private func sectionWorkspace(_ section: NewsRootSection) -> some View {
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $compactColumn) {
            navigationSidebar
                .navigationTitle("The Social Wire")
        } detail: {
            sectionContent(section)
        }
        .navigationSplitViewStyle(.balanced)
    }

    // Keep the workspace alive across fold/resize transitions, including unsent drafts.
    private var phoneTabs: some View {
        TabView(selection: phoneTabSelection) {
            ForEach(sectionPreferences.pinnedSections) { section in
                Tab(value: NewsPhoneTab.section(section)) {
                    sectionContent(section)
                        .toolbar(horizontalSizeClass == .regular ? .hidden : .visible, for: .tabBar)
                } label: {
                    Label(section.title, systemImage: section.systemImage)
                }
                .badge(sectionPreferences.badgeCount(for: .section(section), unreadSocialNotifications: unreadSocialNotifications))
            }
            Tab("Browse", systemImage: "square.grid.3x3", value: NewsPhoneTab.browse) {
                Group {
                    if isBrowsing || sectionPreferences.pinnedSections.contains(selectedSection) {
                        NavigationStack {
                            navigationSidebar
                                .navigationTitle("Browse")
                        }
                    } else {
                        sectionContent(selectedSection)
                    }
                }
                .toolbar(horizontalSizeClass == .regular ? .hidden : .visible, for: .tabBar)
            }
            .badge(sectionPreferences.badgeCount(for: .browse, unreadSocialNotifications: unreadSocialNotifications))
        }
        .tabViewStyle(.tabBarOnly)

    }

    private var unreadSocialNotifications: Int {
        appModel.social.quill?.unreadNotificationCount ?? 0
    }

    private var phoneTabSelection: Binding<NewsPhoneTab> {
        Binding(
            get: {
                isBrowsing ? .browse : sectionPreferences.tab(for: selectedSection)
            },
            set: { tab in
                switch tab {
                case .section(let section):
                    if section == .social {
                        selectedSocialDestination = .timeline
                        socialNavigation.showHome()
                    }
                    isBrowsing = false
                    selectedSection = section
                case .browse:
                    isBrowsing = true
                }
            }
        )
    }
    #endif

    @ViewBuilder
    private var feedTabs: some View {
        feedTabsContent
            .tabViewStyle(.sidebarAdaptable)
    }

    private var navigationSidebar: some View {
        NewsSidebarView(
            availableTabs: availableTabs,
            sceneModel: sceneModel,
            onSelection: {
                sidebarDestinationSelected()
                revealSelectedDestination()
            },
            onListsSelection: { selectSidebarSection(.lists) },
            onSocialSelection: { selectSidebarSection(.social) },
            onProfileSelection: showSocialProfile,
            onStandardListSelection: { list in
                selectSidebarSection(.lists)
                Task { await appModel.standardReaderLists.select(list) }
            },
            selectedSection: selectedSection,
            selectedSocialDestination: selectedSocialDestination,
            onSocialDestinationSelection: { destination in
                selectedSocialDestination = destination
                selectSidebarSection(.social)
            },
            onSectionSelection: selectSidebarSection,
            onCustomize: customizePhoneTabs
        )
    }

    private var customizePhoneTabs: (() -> Void)? {
        #if os(iOS)
        usesPhoneTabs ? { isCustomizationPresented = true } : nil
        #else
        nil
        #endif
    }

    private func showSocialProfile() {
        #if os(iOS)
        guard let viewerDID = appModel.social.quill?.viewerDID ?? appModel.viewerDID else { return }
        #else
        guard let viewerDID = appModel.viewerDID else { return }
        #endif
        socialNavigation.showProfile(viewerDID: viewerDID)
        selectedSocialDestination = .timeline
        selectSidebarSection(.social)
    }

    private func selectSidebarSection(_ section: NewsRootSection) {
        selectedSection = section
        reconcileSectionSelection(section)
        revealSelectedDestination()
    }

    private func revealSelectedDestination() {
        isBrowsing = false
        isSidebarPresented = false
        #if os(iOS)
        compactColumn = .detail
        #endif
    }

    private func showSidebar() {
        #if os(iOS)
        if usesPhoneTabs {
            if horizontalSizeClass == .regular {
                isPersistentSidebarPresented.toggle()
            } else {
                isSidebarPresented.toggle()
            }
            return
        }
        columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
        compactColumn = columnVisibility == .detailOnly ? .detail : .sidebar
        #else
        isSidebarPresented = true
        #endif
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
        } else if let feed = slot.primaryFeed {
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
            usesSidebarNavigation: usesSidebarNavigation,
            onShowSidebar: showSidebar
        )
    }

    private var feedTabsContent: some View {
        TabView(selection: $selectedSection) {
            Tab("Read Later", systemImage: "bookmark", value: NewsRootSection.readLater) {
                sectionPager(.readLater, items: readLaterNavigationItems)
            }
            Tab("News", systemImage: "newspaper", value: NewsRootSection.feeds) {
                sectionPager(.feeds, items: feedDestinations.map(NewsNavigationItem.init(feed:)))
            }
            Tab("Topics", systemImage: "square.grid.2x2", value: NewsRootSection.topics) {
                sectionPager(.topics, items: topicDestinations.map(NewsNavigationItem.init(feed:)))
            }
            Tab("Lists", systemImage: "list.bullet", value: NewsRootSection.lists) {
                listsWorkspace
            }
            Tab("Media", systemImage: "play.rectangle", value: NewsRootSection.media) {
                sectionPager(.media, items: [.podcasts].filter(isVisibleInSettings).map(NewsNavigationItem.init(feed:)))
            }
            Tab("Social", systemImage: "bubble.left.and.text.bubble.right", value: NewsRootSection.social) {
                SocialWorkspaceView(destination: $selectedSocialDestination, navigation: socialNavigation)
            }
        }
    }

    @ViewBuilder
    private func sectionContent(_ section: NewsRootSection) -> some View {
        switch section {
        case .social:
            SocialWorkspaceView(destination: $selectedSocialDestination, navigation: socialNavigation, onShowSidebar: showSidebar)
        case .lists:
            listsWorkspace
        default:
            sectionPager(section, items: navigationItems(for: section), usesSidebarNavigation: usesExternalListsSidebar)
        }
    }

    private var listsWorkspace: some View {
        StandardReaderListsWorkspace(usesExternalSidebar: usesExternalListsSidebar, onShowSidebar: showSidebar)
            .accessibilityIdentifier("news-tab-content-standardLists")
    }

    private var usesExternalListsSidebar: Bool {
        #if os(iOS)
        !usesPhoneTabs || horizontalSizeClass == .regular
        #else
        false
        #endif
    }

    private func sectionPager(
        _ section: NewsRootSection,
        items: [NewsNavigationItem],
        usesSidebarNavigation: Bool = false
    ) -> some View {
        let selection = sectionSelectionBinding(for: section)
        return NewsSectionPager(items: items, selection: selection) { slot in
            destinationContent(
                for: slot,
                navigationItems: items,
                selection: selection,
                usesSidebarNavigation: usesSidebarNavigation
            )
        } emptyContent: {
            NavigationStack {
                ContentUnavailableView(
                    section.emptyTitle,
                    systemImage: section.systemImage,
                    description: Text(section.emptyDescription)
                )
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        NewsSidebarButton(action: showSidebar)
                    }
                }
            }
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
                    // A publication/folder shares its root slot with the aggregate feed.
                    // Explicitly tapping that shortcut must still return to the full feed.
                    if let source = slot.savedListSource ?? slot.primaryFeed?.readerListSource,
                       appModel.feedSelection != .topLevel(source) {
                        sceneModel.resetPath(for: slot.primaryFeed?.newsTab ?? .saved)
                        appModel.selectReaderListSource(source)
                    }
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
        case .media:
            [.podcasts].filter(isVisibleInSettings).map(NewsNavigationItem.init(feed:))
        case .social:
            []
        }
    }

    private func selectedSectionChanged(_ oldValue: NewsRootSection, _ section: NewsRootSection) {
        guard section != .lists, section != .social else { return }
        reconcileSectionSelection(section)
    }

    private func sidebarDestinationSelected() {
        switch sceneModel.selectedTab {
        case .finance, .sports: selectedSection = .topics
        case .podcasts: selectedSection = .media
        case .saved: selectedSection = .readLater
        default: selectedSection = .feeds
        }
        sceneTabChanged(sceneModel.selectedTab, sceneModel.selectedTab)
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
        guard !isTabConfigurationLoaded else { return }
        socialNavigation.bind(viewerDID: appModel.viewerDID)
        sectionPreferences = NewsSectionPreferences.load(viewerDID: appModel.viewerDID)
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
            // Resolve interests before the story request captures its preference
            // fingerprint; a concurrent selection load can otherwise discard it.
            guard await appModel.loadFinanceSelections(), !Task.isCancelled else { return }
            await feeds
            guard !Task.isCancelled else { return }
            async let customization: Void = appModel.loadFinanceCustomization(reconcilingSelections: false)
            async let stories: Void = appModel.loadFinance()
            _ = await (customization, stories)
        case .sports:
            let topic = appModel.sportsTopic
            topic.bind(viewer: appModel.viewerDID)
            await topic.loadCatalog()
            await topic.refresh(language: Locale.current.language.languageCode?.identifier ?? "en")
        case .subscribed, .following, .podcasts:
            break
        }
    }

    private func rootSection(for slot: NewsTabSlot) -> NewsRootSection? {
        if slot.savedListSource != nil { return .readLater }
        if case .standardList = slot { return .lists }
        guard let feed = slot.primaryFeed else { return nil }
        if feed == .podcasts { return .media }
        return [.finance, .sports].contains(feed) ? .topics : .feeds
    }

    private func viewerDidChange(_ oldValue: String?, _ viewerDID: String?) {
        socialNavigation.bind(viewerDID: viewerDID)
        sectionPreferences = NewsSectionPreferences.load(viewerDID: viewerDID)
        selectedSocialDestination = .timeline
        isBrowsing = false
        isSidebarPresented = false
        isCustomizationPresented = false
        isTabConfigurationLoaded = false
        sceneModel.updateContext(viewerDID: viewerDID, availableTabs: availableTabs)
        appModel.loadPrimaryTabPreferences()
        slotFeeds = appModel.primaryTabFeeds
        isTabConfigurationLoaded = true
    }

    private func primaryTabFeedsChanged(
        _ oldValue: [NewsPrimaryFeed],
        _ feeds: [NewsPrimaryFeed]
    ) {
        slotFeeds = feeds
        guard selectedSection != .lists, selectedSection != .social else { return }

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
        guard isTabConfigurationLoaded, selectedSection != .lists, selectedSection != .social else { return }
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
              selectedSection != .social,
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
    let onShowSidebar: () -> Void

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
                        .toolbar {
                            ToolbarItem(placement: .primaryAction) {
                                NewsSidebarButton(action: onShowSidebar)
                            }
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
                #if os(iOS)
                NewsSidebarButton(action: onShowSidebar)
                #else
                Button {
                    isProfilePresented = true
                } label: {
                    ViewerProfileAvatar(size: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Profile")
                #endif
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

#if os(iOS)
private struct NewsSocialBadgeContext: Equatable {
    let viewerDID: String?
    let modelIdentity: ObjectIdentifier?
    let scenePhase: ScenePhase
}
#endif
