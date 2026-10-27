import Foundation
import Observation

/// The account's pinned feeds, as shown in the sidebar alongside the tabs.
@MainActor
@Observable
public final class PinnedFeedsModel {
    public private(set) var feeds: [PinnedFeed] = []
    public private(set) var isLoading = false
    public private(set) var isUpdating = false
    /// Set when the last load failed. Distinguishes "nothing pinned" from "couldn't ask",
    /// which the sidebar words differently.
    public private(set) var didFail = false
    public private(set) var updateFailed = false

    private let source: any PinnedFeedsSource
    private var loadGeneration = 0

    public init(source: any PinnedFeedsSource) {
        self.source = source
    }

    public func isSubscribed(to uri: String) -> Bool {
        feeds.contains { $0.uri.description == uri }
    }

    public func clearUpdateFailure() {
        updateFailed = false
    }

    /// Loads the pinned feeds. A failure leaves whatever was already loaded in place, so a
    /// dropped connection doesn't empty the sidebar.
    public func load() async {
        guard !isLoading else { return }
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        didFail = false
        defer { isLoading = false }

        do {
            let loadedFeeds = try await source.pinnedFeeds { [weak self] initialFeeds in
                await self?.receiveInitialFeeds(initialFeeds, generation: generation)
            }
            try Task.checkCancellation()
            guard generation == loadGeneration else { return }
            receiveInitialFeeds(loadedFeeds, generation: generation)
        } catch is CancellationError {
        } catch {
            if generation == loadGeneration { didFail = true }
        }
    }

    private func receiveInitialFeeds(_ initialFeeds: [PinnedFeed], generation: Int) {
        guard generation == loadGeneration, !Task.isCancelled else { return }
        let existing = feeds.reduce(into: [String: PinnedFeed]()) { $0[$1.id.description] = $1 }
        var seenIDs = Set<String>()
        feeds = initialFeeds.compactMap { feed in
            let id = feed.id.description
            guard seenIDs.insert(id).inserted else { return nil }
            // Retain cached display names while an unresolved generator uses its
            // record key as a placeholder, but publish each resolved name promptly.
            if feed.name == feed.uri.recordKey?.description, let cached = existing[id] {
                return cached
            }
            return feed
        }
    }

    public func move(fromOffsets: IndexSet, toOffset: Int) async {
        var updatedFeeds = feeds
        let validOffsets = fromOffsets.filter { updatedFeeds.indices.contains($0) }
        guard !validOffsets.isEmpty else { return }
        let movingFeeds = validOffsets.sorted().map { updatedFeeds[$0] }
        for index in validOffsets.sorted(by: >) {
            updatedFeeds.remove(at: index)
        }
        let removedBeforeDestination = validOffsets.count { $0 < toOffset }
        let destination = min(max(toOffset - removedBeforeDestination, 0), updatedFeeds.count)
        updatedFeeds.insert(contentsOf: movingFeeds, at: destination)
        await persist(updatedFeeds)
    }

    public func remove(atOffsets: IndexSet) async {
        var updatedFeeds = feeds
        let validOffsets = atOffsets.filter { updatedFeeds.indices.contains($0) }
        guard !validOffsets.isEmpty else { return }
        for index in validOffsets.sorted(by: >) {
            updatedFeeds.remove(at: index)
        }
        await persist(updatedFeeds)
    }

    private func persist(_ updatedFeeds: [PinnedFeed]) async {
        guard !isUpdating else { return }
        loadGeneration += 1
        let previousFeeds = feeds
        feeds = updatedFeeds
        isUpdating = true
        updateFailed = false
        defer { isUpdating = false }
        do {
            try await source.updatePinnedFeeds(updatedFeeds)
        } catch {
            feeds = previousFeeds
            updateFailed = true
        }
    }
}
