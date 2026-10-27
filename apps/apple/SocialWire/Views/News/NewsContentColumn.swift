import SwiftUI

struct NewsContentColumn: View {
    let selectedTab: NewsTab
    let sceneModel: NewsSceneModel

    var body: some View {
        Group {
            switch selectedTab {
            case .wire:
                WireNewsView(sceneModel: sceneModel)
            case .finance:
                FinanceNewsView(sceneModel: sceneModel)
                    .accessibilityIdentifier("news-tab-content-finance")
            case .podcasts:
                PodcastsView()
            case .sports:
                SportsNewsView()
                    .accessibilityIdentifier("news-tab-content-sports")
            case .circle:
                CircleNewsView(sceneModel: sceneModel)
            case .library:
                LibraryNewsView(sceneModel: sceneModel)
            case .saved:
                SavedNewsView(sceneModel: sceneModel)
            case .search:
                PublicationSearchView(query: "")
            }
        }
    }
}
