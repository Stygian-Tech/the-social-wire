import Foundation
import Observation

@Observable
@MainActor
final class OPMLImportModel {
    private(set) var feeds: [OPMLFeed] = []
    private(set) var existingFeedURLs = Set<String>()
    var selectedFeedURLs = Set<String>()
    private(set) var completedCount = 0
    private(set) var totalCount = 0
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

    func updateExistingFeedURLs(_ urls: Set<String>) {
        existingFeedURLs = urls
        selectedFeedURLs = Set(feeds.map(\.feedURL)).subtracting(urls)
        failures = []
        completedCount = 0
    }

    func clear() {
        feeds = []
        selectedFeedURLs = []
        existingFeedURLs = []
        failures = []
        completedCount = 0
        totalCount = 0
        isImporting = false
    }

    func beginImport(total: Int? = nil) {
        totalCount = total ?? selectedFeeds.count
        completedCount = 0
        failures = []
        isImporting = true
    }

    func noteProgress(_ completed: Int) {
        completedCount = completed
    }

    func finishImport(failures: [OPMLImportFailure], successfulFeedURLs: Set<String> = []) {
        existingFeedURLs.formUnion(successfulFeedURLs)
        selectedFeedURLs.subtract(successfulFeedURLs)
        self.failures = failures
        isImporting = false
    }
}
