import SwiftUI

struct LibraryNewsView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    let sceneModel: NewsSceneModel

    var body: some View {
        articlesContent
        .accessibilityIdentifier("news-tab-content-library")
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
                description: Text("Choose a folder or publication from the sidebar to browse its latest stories.")
            )
        }
    }

    private func openSelectedRSSArticle() {
        guard let entryID = appModel.selectedEntry?.entryId else { return }
        sceneModel.navigate(to: .entry(id: entryID), in: .library)
    }
}
