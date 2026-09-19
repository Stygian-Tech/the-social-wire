import SwiftUI

struct LibraryNewsView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    let sceneModel: NewsSceneModel

    var body: some View {
        articlesContent
        .navigationTitle(navigationTitle)
        .accessibilityIdentifier("news-tab-content-library")
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
                description: Text("Choose a folder or publication from the sidebar to browse its latest stories.")
            )
        }
    }

    private var navigationTitle: String {
        appModel.selectedPublication?.title ?? "Library"
    }

    private func openSelectedRSSArticle() {
        guard let entryID = appModel.selectedEntry?.entryId else { return }
        sceneModel.navigate(to: .entry(id: entryID), in: .library)
    }
}
