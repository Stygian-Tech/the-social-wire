import SwiftUI

struct LibraryNewsView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    let sceneModel: NewsSceneModel
    @State private var showingPublications = false

    var body: some View {
        articlesContent
        .accessibilityIdentifier("news-tab-content-library")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Publications", systemImage: "books.vertical") {
                    showingPublications = true
                }
                .accessibilityIdentifier("news-browse-publications")
            }
        }
        .sheet(isPresented: $showingPublications) {
            NavigationStack { LibraryPublicationChooser() }
        }
        .task(id: appModel.feedSelection) {
            await appModel.loadSelectedArticleFeedIfNeeded()
        }
    }

    @ViewBuilder
    private var articlesContent: some View {
        if appModel.selectedPublication != nil || appModel.hasSelectedArticleFeed {
            EntryListView(onEntryOpened: openSelectedRSSArticle)
        } else if appModel.sidebarFetching {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "Select a Publication",
                systemImage: "newspaper",
                description: Text("Choose Publications to browse a folder or publication’s latest stories.")
            )
        }
    }

    private func openSelectedRSSArticle() {
        guard let entryID = appModel.selectedEntry?.entryId else { return }
        sceneModel.navigate(to: .entry(id: entryID), in: .library)
    }
}
