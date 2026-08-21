import SwiftUI

struct MainSplitView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var compactPane: ReaderPane = .publications
    /// Bumped on every compact pane change so async tap handlers can skip stale pager moves.
    @State private var compactNavigationEpoch: UInt = 0
    @State private var showingAddPublication = false
    @State private var showingNewFolder = false
    @State private var showingProfile = false

    private var compact: Bool {
        horizontalSizeClass == .compact
    }

    var body: some View {
        rootContent
            .sheet(isPresented: $showingAddPublication) {
                AddPublicationView()
            }
            .sheet(isPresented: $showingNewFolder) {
                NewFolderView()
            }
            .sheet(isPresented: $showingProfile) {
                NavigationStack {
                    ProfileView()
                }
            }
            .modifier(CompactReaderSelectionHandlers(
                compact: compact,
                compactPane: $compactPane,
                compactNavigationEpoch: $compactNavigationEpoch,
                navigationShape: navigationShape,
                onSidebarSelection: handleSidebarSelection,
                onCompactPaneChange: handleCompactPaneChange
            ))
    }

    @ViewBuilder
    private var rootContent: some View {
        if compact {
            compactPagedReader
        } else {
            regularSplitView
        }
    }

    // MARK: - Regular (iPad)

    private var navigationShape: ReaderNavigationShape {
        appModel.readerListSource.navigationShape
    }

    private var regularSplitView: some View {
        NavigationStack {
            Group {
                if navigationShape.showsArticlesColumn {
                    NavigationSplitView(columnVisibility: $columnVisibility) {
                        ReaderSidebarColumn(
                            showingNewFolder: $showingNewFolder,
                            showingAddPublication: $showingAddPublication
                        )
                    } content: {
                        articlesColumn
                    } detail: {
                        detailColumn
                    }
                    .navigationSplitViewStyle(.balanced)
                } else {
                    NavigationSplitView(columnVisibility: $columnVisibility) {
                        ReaderSidebarColumn(
                            showingNewFolder: $showingNewFolder,
                            showingAddPublication: $showingAddPublication
                        )
                    } detail: {
                        detailColumn
                    }
                    .navigationSplitViewStyle(.balanced)
                }
            }
            .navigationTitle("The Social Wire")
            .navigationBarTitleDisplayMode(.inline)
            .readerShellOverlay(showingProfile: $showingProfile, compactPane: nil)
        }
    }

    // MARK: - Compact (iPhone pager)

    private var compactPagedReader: some View {
        NavigationStack {
            compactReaderTabView
                .navigationTitle(compactNavigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .readerShellOverlay(showingProfile: $showingProfile, compactPane: compactPane)
        }
    }

    @ViewBuilder
    private var compactReaderTabView: some View {
        switch navigationShape {
        case .publicationFeed:
            compactFourPaneTabView
        case .savedLinks:
            compactThreePaneTabView
        case .wire:
            compactWireTabView
        }
    }

    /// Subscribed / Following: lists → publications → articles → reader (tags 0…3).
    private var compactFourPaneTabView: some View {
        compactTabView {
            ListsView(onListSourceTap: openListSource)
                .tag(0)

            PublicationsPaneView(
                showingNewFolder: $showingNewFolder,
                showingAddPublication: $showingAddPublication,
                onPublicationTap: openPublication,
                onSavedLinkTap: openSavedLink
            )
            .tag(1)

            articlesColumn
                .tag(2)

            readerColumn
                .tag(3)
        }
        .id("compact-four-pane")
    }

    /// Read Later / Archive: lists → saved links → reader (contiguous tags 0…2).
    private var compactThreePaneTabView: some View {
        compactTabView {
            ListsView(onListSourceTap: openListSource)
                .tag(0)

            PublicationsPaneView(
                showingNewFolder: $showingNewFolder,
                showingAddPublication: $showingAddPublication,
                onPublicationTap: openPublication,
                onSavedLinkTap: openSavedLink
            )
            .tag(1)

            readerColumn
                .tag(2)
        }
        .id("compact-three-pane")
    }

    /// The Wire: lists → ranked articles → reader (contiguous tags 0…2).
    private var compactWireTabView: some View {
        compactTabView {
            ListsView(onListSourceTap: openListSource)
                .tag(0)

            articlesColumn
                .tag(1)

            readerColumn
                .tag(2)
        }
        .id("compact-wire-three-pane")
    }

    private func compactTabView<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        TabView(selection: compactTabSelection) {
            content()
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .animation(.easeInOut(duration: 0.28), value: compactPane)
    }

    private var compactTabSelection: Binding<Int> {
        Binding(
            get: { compactPane.compactTabTag(navigationShape: navigationShape) ?? 0 },
            set: { newTag in
                let clamped = min(max(newTag, 0), navigationShape.compactPanes.count - 1)
                let newPane = ReaderPane.fromCompactTabTag(
                    clamped,
                    navigationShape: navigationShape
                )
                guard newPane != compactPane else { return }
                compactPane = newPane
            }
        )
    }

    private func navigateCompactPane(
        _ pane: ReaderPane,
        animated: Bool = false,
        afterEpoch requestedEpoch: UInt? = nil
    ) {
        guard CompactReaderNavigation.shouldCompleteDeferredNavigation(
            requestedEpoch: requestedEpoch ?? compactNavigationEpoch,
            currentEpoch: compactNavigationEpoch
        ) else { return }
        setCompactPane(to: pane, animated: animated)
    }

    private var compactNavigationTitle: String {
        switch compactPane {
        case .lists:
            "Lists"
        case .publications:
            appModel.readerListSource.rawValue
        case .articles:
            appModel.readerListSource == .wire ? "The Wire" : "Articles"
        case .reader:
            if let entry = appModel.selectedEntry {
                entry.title
            } else if let save = appModel.selectedSavedLink {
                save.title
            } else {
                "Reader"
            }
        }
    }

    // MARK: - Columns

    @ViewBuilder
    private var articlesColumn: some View {
        if appModel.selectedSidebar == .myPublications {
            PublicationCollectionView(title: "My Publications", publications: appModel.myPublications)
        } else if appModel.hasSelectedArticleFeed {
            EntryListView(
                navigationEpoch: compact ? { compactNavigationEpoch } : nil,
                onEntryOpened: compact ? { epoch in
                    navigateCompactPane(.reader, animated: true, afterEpoch: epoch)
                } : nil
            )
        } else if appModel.sidebarFetching {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            selectPublicationPlaceholder
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let save = appModel.selectedSavedLink {
            SavedLinkDetailView(save: save)
        } else if let entry = appModel.selectedEntry {
            EntryDetailView(entry: entry)
        } else {
            chooseArticlePlaceholder
        }
    }

    @ViewBuilder
    private var readerColumn: some View {
        if let save = appModel.selectedSavedLink {
            SavedLinkDetailView(save: save)
        } else if let entry = appModel.selectedEntry {
            EntryDetailView(entry: entry)
        } else {
            chooseArticlePlaceholder
        }
    }

    private var selectPublicationPlaceholder: some View {
        ContentUnavailableView(
            "Select a Publication",
            systemImage: "newspaper",
            description: Text("Select a publication from the list to see articles.")
        )
    }

    private var chooseArticlePlaceholder: some View {
        ContentUnavailableView(
            "Select an Article",
            systemImage: "doc.text",
            description: Text(chooseArticlePlaceholderDescription)
        )
    }

    private var chooseArticlePlaceholderDescription: String {
        if appModel.readerListSource == .wire {
            "Select an article from The Wire."
        } else if appModel.selectedPublication != nil {
            "Select an article from the list."
        } else if appModel.selectedSavedLink != nil {
            "Your saved link is open in the reader."
        } else {
            "Select a publication or saved link to start reading."
        }
    }

    // MARK: - Compact navigation actions

    private func setCompactPane(to pane: ReaderPane, animated: Bool) {
        var transaction = Transaction()
        if !animated {
            transaction.disablesAnimations = true
        }
        withTransaction(transaction) {
            compactPane = pane
        }
    }

    private func openListSource(_ source: ReaderListSource) {
        appModel.selectReaderListSource(source)
        let target = CompactReaderNavigation.paneAfterListSource(source)
        navigateCompactPane(target, animated: true)
    }

    private func openPublication(_ publication: DiscoveredPublication) {
        let epoch = compactNavigationEpoch
        Task {
            if appModel.selectedPublication?.publicationId != publication.publicationId {
                await appModel.selectPublication(publication)
            }
            navigateCompactPane(
                CompactReaderNavigation.paneAfterPublication(appModel.readerListSource),
                animated: true,
                afterEpoch: epoch
            )
        }
    }

    private func openSavedLink(_ save: MergedLatrSave) {
        appModel.selectedEntry = nil
        appModel.selectedSavedLink = save
        navigateCompactPane(CompactReaderNavigation.paneAfterDetail(), animated: true)
    }

    // MARK: - Selection

    private func handleSidebarSelection(_ selection: SidebarSelection?) async {
        guard let selection else {
            if appModel.readerListSource != .readLater && appModel.readerListSource != .archive {
                appModel.selectedEntry = nil
                // Compact publications pane: keep the active publication when clearing list
                // selection so re-tapping the same row can navigate back to Articles.
                if !(compact && compactPane == .publications) {
                    if case .publication = appModel.feedSelection {
                        appModel.selectedPublication = nil
                        appModel.entries = []
                    }
                }
            }
            return
        }
        switch selection {
        case .publication(let id):
            if let publication = appModel.publication(forId: id),
               appModel.selectedPublication?.publicationId != id
            {
                await appModel.selectPublication(publication)
            }
        case .saved:
            if appModel.readerListSource != .readLater && appModel.readerListSource != .archive {
                appModel.selectReaderListSource(.readLater)
            }
        case .myPublications:
            appModel.selectedEntry = nil
            appModel.selectedSavedLink = nil
            appModel.selectedPublication = nil
            appModel.entries = []
        }
    }

    private func handleCompactPaneChange(from oldPane: ReaderPane, to newPane: ReaderPane) {
        guard compact else { return }
        let transition = CompactReaderNavigation.swipeTransition(
            from: oldPane,
            to: newPane,
            navigationShape: navigationShape
        )
        if transition.clearsReaderDetail {
            Task {
                await appModel.dismissReaderDetail()
                appModel.dismissSavedLinkDetail()
            }
        }
        if transition.clearsArticleSelection {
            appModel.selectedEntry = nil
            appModel.selectedSavedLink = nil
            appModel.selectedSidebar = nil
        }
        if transition.clearsFeedState {
            appModel.selectedEntry = nil
            appModel.selectedSavedLink = nil
            appModel.selectedPublication = nil
            appModel.selectedSidebar = nil
            appModel.entries = []
        }
    }
}

/// Keeps `MainSplitView.body` type-checkable; wires compact selection → pager navigation.
private struct CompactReaderSelectionHandlers: ViewModifier {
    @Environment(SocialWireAppModel.self) private var appModel
    let compact: Bool
    @Binding var compactPane: ReaderPane
    @Binding var compactNavigationEpoch: UInt
    let navigationShape: ReaderNavigationShape
    let onSidebarSelection: (SidebarSelection?) async -> Void
    let onCompactPaneChange: (ReaderPane, ReaderPane) -> Void

    func body(content: Content) -> some View {
        @Bindable var model = appModel

        content
            .onAppear {
                guard compact else { return }
                if let normalized = CompactReaderNavigation.normalizedPaneAfterLayoutChange(
                    compactPane: compactPane,
                    navigationShape: navigationShape
                ) {
                    compactPane = normalized
                }
            }
            .onChange(of: model.selectedSidebar) { _, selection in
                Task { await onSidebarSelection(selection) }
            }
            .onChange(of: model.readerListSource) { _, source in
                guard compact else { return }
                if let remapped = CompactReaderNavigation.remapPaneAfterListSourceChange(
                    compactPane: compactPane,
                    newSource: source
                ) {
                    compactPane = remapped
                }
            }
            .onChange(of: navigationShape) { _, shape in
                guard compact else { return }
                if let normalized = CompactReaderNavigation.normalizedPaneAfterLayoutChange(
                    compactPane: compactPane,
                    navigationShape: shape
                ) {
                    compactPane = normalized
                }
            }
            .onChange(of: compactPane) { oldPane, newPane in
                guard compact else { return }
                guard oldPane != newPane else { return }
                compactNavigationEpoch &+= 1
                // Defer side effects so `TabView` page transitions can settle first.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(320))
                    guard compactPane == newPane else { return }
                    onCompactPaneChange(oldPane, newPane)
                }
            }
    }
}
