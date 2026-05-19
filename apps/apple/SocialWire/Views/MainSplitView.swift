import SwiftUI

struct MainSplitView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var compactPane: ReaderPane = .publications
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
            .refreshable {
                await appModel.refreshAll()
            }
            .modifier(CompactReaderSelectionHandlers(
                compact: compact,
                compactPane: $compactPane,
                onSidebarSelection: handleSidebarSelection,
                onCompactPaneChange: handleCompactPaneChange,
                onNavigatePane: navigateCompactPane
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

    private var regularSplitView: some View {
        NavigationStack {
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

    private var compactReaderTabView: some View {
        TabView(selection: $compactPane) {
            ListsView(navigateToPane: navigateCompactPane)
                .tag(ReaderPane.lists)

            PublicationsPaneView(
                showingNewFolder: $showingNewFolder,
                showingAddPublication: $showingAddPublication,
                navigateToPane: navigateCompactPane
            )
            .tag(ReaderPane.publications)

            articlesColumn
                .tag(ReaderPane.articles)

            readerColumn
                .tag(ReaderPane.reader)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .animation(Self.compactPaneAnimation, value: compactPane)
    }

    private func navigateCompactPane(_ pane: ReaderPane) {
        setCompactPane(to: pane)
    }

    private var compactNavigationTitle: String {
        switch compactPane {
        case .lists:
            "Lists"
        case .publications:
            appModel.readerListSource.rawValue
        case .articles:
            "Articles"
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
        switch appModel.readerListSource {
        case .readLater:
            readLaterArticlesPlaceholder
        case .subscribed, .following:
            if appModel.selectedSidebar == .myPublications {
                PublicationCollectionView(title: "My Publications", publications: appModel.myPublications)
            } else if appModel.selectedPublication != nil {
                EntryListView()
            } else {
                selectPublicationPlaceholder
            }
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

    private var readLaterArticlesPlaceholder: some View {
        ContentUnavailableView(
            "Read Later",
            systemImage: "bookmark",
            description: Text("Select a saved link in Publications, then open it in the reader.")
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
        if appModel.selectedPublication != nil {
            "Select an article from the list."
        } else if appModel.selectedSavedLink != nil {
            "Your saved link is open in the reader."
        } else {
            "Select a publication or saved link to start reading."
        }
    }

    // MARK: - Compact pager

    private func setCompactPane(to pane: ReaderPane) {
        compactPane = pane
    }

    private static var compactPaneAnimation: Animation {
        .easeInOut(duration: 0.35)
    }

    // MARK: - Selection

    private func handleSidebarSelection(_ selection: SidebarSelection?) async {
        guard let selection else {
            if appModel.readerListSource != .readLater {
                appModel.selectedEntry = nil
                appModel.selectedPublication = nil
                appModel.entries = []
            }
            return
        }
        switch selection {
        case .publication(let id):
            if let publication = appModel.allPublicationRows.first(where: { $0.publicationId == id }) {
                await appModel.selectPublication(publication)
            }
        case .saved:
            if appModel.readerListSource != .readLater {
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
        if newPane == .articles, oldPane == .reader {
            Task {
                await appModel.dismissReaderDetail()
                appModel.dismissSavedLinkDetail()
            }
        }
        if newPane == .publications, oldPane == .articles {
            appModel.selectedEntry = nil
            appModel.selectedSavedLink = nil
        }
        if newPane == .lists, oldPane != .lists {
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
    let onSidebarSelection: (SidebarSelection?) async -> Void
    let onCompactPaneChange: (ReaderPane, ReaderPane) -> Void
    let onNavigatePane: (ReaderPane) -> Void

    func body(content: Content) -> some View {
        @Bindable var model = appModel

        content
            .onChange(of: model.selectedSidebar) { _, selection in
                Task { await onSidebarSelection(selection) }
            }
            .onChange(of: model.selectedPublication?.publicationId) { _, publicationId in
                guard compact, publicationId != nil else { return }
                onNavigatePane(.articles)
            }
            .onChange(of: model.selectedEntry?.entryId) { _, entryId in
                guard compact, entryId != nil else { return }
                onNavigatePane(.reader)
            }
            .onChange(of: model.selectedSavedLink?.id) { _, saveId in
                guard compact, saveId != nil else { return }
                onNavigatePane(.reader)
            }
            .onChange(of: compactPane) { oldPane, newPane in
                guard compact else { return }
                onCompactPaneChange(oldPane, newPane)
            }
    }
}
