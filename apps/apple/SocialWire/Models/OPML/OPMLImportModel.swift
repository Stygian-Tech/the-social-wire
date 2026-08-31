import Foundation
import Observation

@Observable
@MainActor
final class OPMLImportModel {
    private(set) var feeds: [OPMLFeed] = []
    private(set) var existingFeedURLs = Set<String>()
    var selectedFeedURLs = Set<String>()
    private(set) var completedCount = 0
    private(set) var failures: [OPMLImportFailure] = []
    private(set) var isImporting = false
    var errorMessage: String?

    var selectedFeeds: [OPMLFeed] {
        feeds.filter { selectedFeedURLs.contains($0.feedURL) && !existingFeedURLs.contains($0.feedURL) }
    }

    func load(data: Data, existingFeedURLs: Set<String>) {
        do {
            feeds = try OPMLParser.parse(data)
            self.existingFeedURLs = existingFeedURLs
            selectedFeedURLs = Set(feeds.lazy.map(\.feedURL)).subtracting(existingFeedURLs)
            completedCount = 0
            failures = []
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func beginImport() {
        completedCount = 0
        failures = []
        isImporting = true
    }

    func noteProgress(_ completed: Int) {
        completedCount = completed
    }

    func finishImport(failures: [OPMLImportFailure]) {
        self.failures = failures
        isImporting = false
    }
}
