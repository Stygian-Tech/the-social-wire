import Foundation

enum PodcastLibraryDestination: String, Identifiable, CaseIterable {
    case recentlyAdded, downloaded, upNext
    var id: Self { self }
    var title: String {
        switch self { case .recentlyAdded: "Recently Added"; case .downloaded: "Downloaded"; case .upNext: "Up Next" }
    }
    var systemImage: String {
        switch self { case .recentlyAdded: "clock"; case .downloaded: "arrow.down.circle"; case .upNext: "text.line.first.and.arrowtriangle.forward" }
    }
}
