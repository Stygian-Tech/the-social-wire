import SwiftUI

struct MainSplitView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var showingAddPublication = false
    @State private var showingNewFolder = false
    @State private var showingSettings = false

    private var compact: Bool {
        horizontalSizeClass == .compact
    }

    private var publicationSidebarSelectionActive: Bool {
        if case .publication = appModel.selectedSidebar {
            true
        } else {
            false
        }
    }

    var body: some View {
        @Bindable var model = appModel

        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                showingAddPublication: $showingAddPublication,
                showingNewFolder: $showingNewFolder,
                showingSettings: $showingSettings
            )
        } content: {
            contentColumn
        } detail: {
            detailColumn
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $showingAddPublication) {
            AddPublicationView()
        }
        .sheet(isPresented: $showingNewFolder) {
            NewFolderView()
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsView()
            }
        }
        .refreshable {
            await appModel.refreshAll()
        }
        .onChange(of: model.selectedSidebar) { _, selection in
            Task { await handleSidebarSelection(selection) }
        }
    }

    @ViewBuilder
    private var contentColumn: some View {
        switch appModel.selectedSidebar {
        case .saved:
            SavedLinksView()
        case .myPublications:
            PublicationCollectionView(title: "My Publications", publications: appModel.myPublications)
        case .publication:
            ZStack {
                EntryListView(
                    hidesNavigationChrome: compact && appModel.selectedEntry != nil
                )
                if compact, let entry = appModel.selectedEntry {
                    EntryDetailView(entry: entry)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(.systemBackground))
                        .transition(.opacity)
                }
            }
        case .none:
            selectPublicationPlaceholder
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        if compact && appModel.selectedSidebar == .saved {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if compact && appModel.selectedEntry != nil, publicationSidebarSelectionActive {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let save = appModel.selectedSavedLink {
            SavedLinkDetailView(save: save)
        } else if let entry = appModel.selectedEntry {
            EntryDetailView(entry: entry)
        } else {
            chooseArticlePlaceholder
        }
    }

    private var selectPublicationPlaceholder: some View {
        ContentUnavailableView {
            Label("Select a Publication", systemImage: "newspaper")
        } description: {
            Text("Choose a publication from the sidebar to start reading.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var chooseArticlePlaceholder: some View {
        ContentUnavailableView {
            Label("Choose an Article", systemImage: "doc.text")
        } description: {
            if appModel.selectedPublication != nil {
                Text("Select an article from the list.")
            } else {
                Text("Choose a publication from the sidebar to start reading.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func handleSidebarSelection(_ selection: SidebarSelection?) async {
        guard let selection else {
            appModel.selectedEntry = nil
            appModel.selectedSavedLink = nil
            appModel.selectedPublication = nil
            appModel.entries = []
            return
        }
        switch selection {
        case .publication(let id):
            if let publication = appModel.allPublicationRows.first(where: { $0.publicationId == id }) {
                await appModel.selectPublication(publication)
            }
        case .saved:
            appModel.selectedEntry = nil
            appModel.selectedPublication = nil
            appModel.entries = []
            appModel.selectedSavedLink = nil
        case .myPublications:
            appModel.selectedEntry = nil
            appModel.selectedSavedLink = nil
            appModel.selectedPublication = nil
            appModel.entries = []
        }
    }
}
