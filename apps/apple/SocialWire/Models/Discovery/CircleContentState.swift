enum CircleContentState: Equatable {
    case loading
    case notReady
    case refreshing
    case buildingNetwork
    case noVisibleStories
    case failed
    case stories

    init(
        catalog: CircleFeedCatalog?,
        storyCount: Int?,
        visibleStoryCount: Int,
        isLoading: Bool,
        errorMessage: String?,
        limitedCoverage: Bool = false
    ) {
        if visibleStoryCount > 0 {
            self = .stories
        } else if isLoading {
            self = .loading
        } else if errorMessage != nil {
            self = .failed
        } else if let catalog, !catalog.isAvailable {
            self = .notReady
        } else if storyCount == 0, limitedCoverage {
            self = .refreshing
        } else if let storyCount {
            self = storyCount == 0 ? .buildingNetwork : .noVisibleStories
        } else {
            self = .loading
        }
    }
}
