import SwiftUI

struct NewsContentColumn: View {
    let selectedTab: NewsTab
    let sceneModel: NewsSceneModel

    var body: some View {
        Group {
            switch selectedTab {
            case .wire:
                WireNewsView(sceneModel: sceneModel)
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
