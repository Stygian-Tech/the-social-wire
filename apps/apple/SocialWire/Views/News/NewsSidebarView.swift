import SwiftUI

struct NewsSidebarView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    let availableTabs: [NewsTab]
    let sceneModel: NewsSceneModel
    let onSelection: () -> Void
    let onListsSelection: () -> Void
    let onSocialSelection: () -> Void
    let onProfileSelection: () -> Void
    let onStandardListSelection: (StandardReaderList) -> Void
    var selectedSection: NewsRootSection = .feeds
    var selectedSocialDestination: SocialDestination = .timeline
    var onSocialDestinationSelection: ((SocialDestination) -> Void)?
    var onSectionSelection: (NewsRootSection) -> Void = { _ in }
    var onCustomize: (() -> Void)?
    @State private var presentedSheet: NewsSidebarSheet?
    @State private var unavailableTool: NewsSidebarTool?
    @State private var savedSourcesExpanded = false
    @State private var archiveSourcesExpanded = false

    var body: some View {
        List {
            savedSection
            socialSection
            if availableTabs.contains(.podcasts) { mediaSection }
            feedsSection
            if availableTabs.contains(.finance) || availableTabs.contains(.sports) { topicsSection }
            toolsSection
            listsSection
            if let onCustomize {
                Section {
                    Button(action: onCustomize) {
                        Label("Customize Bottom Bar", systemImage: "slider.horizontal.3")
                            .readerFullWidthTapLabel()
                    }
                    .accessibilityIdentifier("news-customize-sections")
                }
            }
        }
        .listStyle(.plain)
        .contentMargins(.horizontal, 0, for: .scrollContent)
        .listRowSeparator(.hidden)
        .listSectionSeparator(.hidden)
        .accessibilityIdentifier("news-sidebar")
        .listItemTint(.accentColor)
        .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
        .toolbar {
            if selectedSection == .feeds && sceneModel.selectedTab == .library && appModel.readerListSource == .subscribed {
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
        .alert(
            unavailableTool?.title ?? "Tool Unavailable",
            isPresented: Binding(
                get: { unavailableTool != nil },
                set: { if !$0 { unavailableTool = nil } }
            ),
            presenting: unavailableTool
        ) { _ in
            Button("OK", role: .cancel) { unavailableTool = nil }
        } message: { tool in
            Text("\(tool.title) is available in Social Wire on the web. This feature is not yet available in the native app.")
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

    private var socialSection: some View {
        Section {
            ForEach([SocialDestination.timeline, .explore, .notifications, .messages, .bookmarks, .lists, .feeds]) { destination in
                Button {
                    if let onSocialDestinationSelection {
                        onSocialDestinationSelection(destination)
                    } else {
                        onSocialSelection()
                    }
                } label: {
                    HStack {
                        Label(destination == .timeline ? "Home" : destination.title, systemImage: destination == .timeline ? "house" : destination.systemImage)
                        Spacer(minLength: 8)
                        if destination == .notifications, unreadNotificationCount > 0 {
                            SidebarCountLabel(count: unreadNotificationCount, accessibilityDescription: "unread notifications")
                        } else if destination == .messages, unreadMessageCount > 0 {
                            SidebarCountLabel(count: unreadMessageCount, accessibilityDescription: "unread messages")
                        }
                    }
                    .readerFullWidthTapLabel()
                }
                .buttonStyle(.plain)
                .readerSidebarListRow()
                .accessibilityIdentifier("news-social-\(destination.rawValue)")
                .listRowBackground(selectedSection == .social && selectedSocialDestination == destination ? Color.accentColor.opacity(0.12) : .clear)
                .accessibilityAddTraits(
                    selectedSection == .social && selectedSocialDestination == destination ? .isSelected : []
                )
            }
        } header: {
            NewsSidebarSectionHeader(section: .social, onSelect: onSectionSelection)
        }
    }

    private var unreadMessageCount: Int {
        appModel.social.messages.conversations.reduce(0) { $0 + $1.unreadCount }
    }

    private var unreadNotificationCount: Int {
        #if os(iOS)
        if let quill = appModel.social.quill { return quill.unreadNotificationCount }
        #endif
        return appModel.social.notifications.unreadCount
    }

    @ViewBuilder
    private var mediaSection: some View {
        if availableTabs.contains(.podcasts) {
            Section {
                destinationRow(.podcasts)
            } header: {
                sectionHeader("Audio", section: .media)
            }
        }
    }

    private var feedsSection: some View {
        Section {
            if availableTabs.contains(.wire) { destinationRow(.wire) }
            if availableTabs.contains(.circle) { destinationRow(.circle) }
            if appModel.visibleReaderListSources.contains(.subscribed) { sourceRow(.subscribed) }
            if appModel.visibleReaderListSources.contains(.following) { sourceRow(.following) }
        } header: {
            sectionHeader("News", section: .feeds)
        }
    }

    @ViewBuilder
    private var toolsSection: some View {
        if !NewsSidebarTool.availableTools.isEmpty {
            Section("Tools") {
                ForEach(NewsSidebarTool.availableTools) { tool in
                    Button {
                        unavailableTool = tool
                    } label: {
                        HStack {
                            Label(tool.title, systemImage: tool.systemImage)
                            Spacer(minLength: 8)
                            Text("Web")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .readerFullWidthTapLabel()
                    }
                    .buttonStyle(.plain)
                    .readerSidebarListRow()
                    .accessibilityIdentifier("news-tool-\(tool.rawValue)")
                    .accessibilityHint("Not yet available in the native app")
                }
            }
        }
    }

    private func sectionHeader(_ title: LocalizedStringKey, section: NewsRootSection) -> some View {
        Button {
            onSectionSelection(section)
        } label: {
            Text(title)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .textCase(nil)
        .accessibilityIdentifier("sidebar-section-\(section.rawValue)")
    }

    @ViewBuilder
    private var topicsSection: some View {
        if availableTabs.contains(.finance) || availableTabs.contains(.sports) {
            Section {
                if availableTabs.contains(.finance) { destinationRow(.finance) }
                if availableTabs.contains(.sports) { destinationRow(.sports) }
            } header: {
                NewsSidebarSectionHeader(section: .topics, onSelect: onSectionSelection)
            }
        }
    }

    @ViewBuilder
    private var listsSection: some View {
        Section("Lists") {
            Button(action: onListsSelection) {
                Label("Lists", systemImage: "list.bullet")
                    .readerFullWidthTapLabel()
            }
                .buttonStyle(.plain)
                .readerSidebarListRow()
                .accessibilityIdentifier("news-tab-button-standardLists")
                .listRowBackground(selectedSection == .lists && appModel.standardReaderLists.selectedList == nil ? Color.accentColor.opacity(0.12) : .clear)
            ForEach(appModel.standardReaderLists.lists) { list in
                Button {
                    onStandardListSelection(list)
                } label: {
                    FeedSidebarRowLabel(
                        title: list.name,
                        systemImage: "list.bullet",
                        unreadCount: nil
                    )
                }
                .buttonStyle(.plain)
                .readerSidebarListRow()
                .listRowBackground(selectedSection == .lists && appModel.standardReaderLists.selectedList?.uri == list.uri ? Color.accentColor.opacity(0.12) : .clear)
                .accessibilityAddTraits(
                    selectedSection == .lists && appModel.standardReaderLists.selectedList?.uri == list.uri ? .isSelected : []
                )
            }
        }
    }

    private var savedSection: some View {
        Section("Read Later") {
            sourceRow(.readLater)
            if appModel.visibleReaderListSources.contains(.archive) {
                sourceRow(.archive)
            }
        }
    }

    private var savedPublicationSources: some View {
        ForEach(appModel.currentSavedFeedSources) { source in
            Button {
                appModel.selectSavedFeedSource(source)
                select(.saved)
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

    private func destinationRow(_ tab: NewsTab) -> some View {
        Button {
            select(tab)
        } label: {
            HStack {
                FeedSidebarRowLabel(
                    title: tab.title,
                    systemImage: tab.systemImage,
                    unreadCount: nil
                )
                if [.podcasts, .finance, .sports].contains(tab) {
                    Text("Beta")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
        }
        .buttonStyle(.plain)
        .readerSidebarListRow()
        .accessibilityIdentifier("news-tab-button-\(tab.rawValue)")
        .listRowBackground(selectedSection == section(for: tab) && sceneModel.selectedTab == tab ? Color.accentColor.opacity(0.12) : .clear)
        .accessibilityAddTraits(selectedSection == section(for: tab) && sceneModel.selectedTab == tab ? .isSelected : [])
    }

    private func sourceRow(_ source: ReaderListSource) -> some View {
        DisclosureGroup(isExpanded: sourceExpansion(for: source)) {
            sourceContents(for: source)
        } label: {
            sourceSelectionButton(source)
        }
        .readerSidebarListRow()
        .accessibilityIdentifier("news-source-disclosure-\(source.preferenceKey)")
    }

    @ViewBuilder
    private func sourceContents(for source: ReaderListSource) -> some View {
        switch source {
        case .subscribed:
            SubscribedPublicationSidebarTree(
                showingNewFolder: sheetBinding(for: .newFolder),
                showingAddPublication: sheetBinding(for: .addPublication),
                onFolderTap: showLibraryContent,
                onPublicationTap: { openPublication($0, source: .subscribed) }
            )
        case .following:
            FollowingPublicationSidebarTree(
                onPublicationTap: { openPublication($0, source: .following) }
            )
        case .readLater, .archive:
            if appModel.readerListSource == source {
                savedPublicationSources
            }
        case .wire:
            EmptyView()
        }
    }

    private func sourceSelectionButton(_ source: ReaderListSource) -> some View {
        let tab: NewsTab = source == .readLater || source == .archive ? .saved : .library
        let isSelected = selectedSection == (tab == .saved ? .readLater : .feeds)
            && sceneModel.selectedTab == tab
            && appModel.feedSelection == .topLevel(source)
        return Button {
            appModel.selectReaderListSource(source)
            select(tab)
        } label: {
            FeedSidebarRowLabel(
                title: source == .readLater ? "Saved" : source.rawValue,
                systemImage: source.systemImage,
                unreadCount: displayedUnreadCount(for: source)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(source == .readLater ? "news-saved" : "news-source-\(source.preferenceKey)")
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.12) : .clear)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func sourceExpansion(for source: ReaderListSource) -> Binding<Bool> {
        Binding(
            get: {
                switch source {
                case .subscribed: appModel.sidebarSubscribedFeedExpanded
                case .following: appModel.sidebarFollowingFeedExpanded
                case .readLater: savedSourcesExpanded
                case .archive: archiveSourcesExpanded
                case .wire: false
                }
            },
            set: { expanded in
                switch source {
                case .subscribed: appModel.sidebarSubscribedFeedExpanded = expanded
                case .following: appModel.sidebarFollowingFeedExpanded = expanded
                case .readLater: savedSourcesExpanded = expanded
                case .archive: archiveSourcesExpanded = expanded
                case .wire: break
                }
                appModel.noteSidebarExpandedPresentationChanged()
            }
        )
    }

    private func section(for tab: NewsTab) -> NewsRootSection {
        switch tab {
        case .finance, .sports: .topics
        case .podcasts: .media
        case .saved: .readLater
        default: .feeds
        }
    }

    private func select(_ tab: NewsTab) {
        sceneModel.select(tab, availableTabs: availableTabs)
        onSelection()
    }

    private func openPublication(_ publication: DiscoveredPublication, source: ReaderListSource) {
        Task {
            appModel.selectReaderListSource(source)
            await appModel.selectPublication(publication)
            guard appModel.selectedPublication?.publicationId == publication.publicationId else { return }
            sceneModel.resetPath(for: .library)
            showLibraryContent()
        }
    }

    private func showLibraryContent() {
        select(.library)
    }

    private func displayedUnreadCount(for source: ReaderListSource) -> Int? {
        guard appModel.showsTopLevelFeedUnreadCount(for: source) else { return nil }
        return appModel.topLevelUnreadCount(for: source)
    }

    private var profileButton: some View {
        Button {
            onProfileSelection()
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
