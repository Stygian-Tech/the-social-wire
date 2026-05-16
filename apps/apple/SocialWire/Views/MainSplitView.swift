import SwiftUI

struct MainSplitView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var showingAddPublication = false
    @State private var showingNewFolder = false

    var body: some View {
        @Bindable var model = appModel

        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                showingAddPublication: $showingAddPublication,
                showingNewFolder: $showingNewFolder
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
        .refreshable {
            await appModel.refreshAll()
        }
        .onChange(of: model.selectedSidebar) { _, selection in
            Task { await handleSidebarSelection(selection) }
        }
    }

    @ViewBuilder
    private var contentColumn: some View {
        switch appModel.selectedSidebar ?? .readingList {
        case .readingList:
            PublicationCollectionView(title: "Reading List", publications: appModel.unfolderedPublications)
        case .saved:
            SavedLinksView()
        case .myPublications:
            PublicationCollectionView(title: "My Publications", publications: appModel.myPublications)
        case .following:
            PublicationCollectionView(title: "Following", publications: appModel.followingPublications)
        case .hidden:
            PublicationCollectionView(title: "Hidden Publications", publications: appModel.hiddenPublications)
        case .settings:
            SettingsView()
        case .folder(let folderURI):
            if let folder = appModel.folders.first(where: { $0.uri == folderURI }) {
                PublicationCollectionView(title: folder.value.name, publications: appModel.publications(in: folder))
            } else {
                ContentUnavailableView("Folder Missing", systemImage: "folder")
            }
        case .publication:
            EntryListView()
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let save = appModel.selectedSavedLink {
            SavedLinkDetailView(save: save)
        } else if let entry = appModel.selectedEntry {
            EntryDetailView(entry: entry)
        } else {
            ContentUnavailableView("Select an Item", systemImage: "doc.text", description: Text("Choose an article or saved link to preview."))
        }
    }

    private func handleSidebarSelection(_ selection: SidebarSelection?) async {
        guard let selection else { return }
        switch selection {
        case .publication(let id):
            if let publication = appModel.publications.first(where: { $0.publicationId == id }) {
                await appModel.selectPublication(publication)
            }
        default:
            appModel.selectedEntry = nil
            appModel.selectedSavedLink = nil
        }
    }
}
