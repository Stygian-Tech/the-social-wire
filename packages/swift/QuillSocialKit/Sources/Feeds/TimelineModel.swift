import Foundation
import Observation

@MainActor
@Observable
public final class TimelineModel {
    public private(set) var posts: [TimelinePost] = [] {
        didSet { threadGroups = TimelineThreadGroup.grouping(posts) }
    }
    public private(set) var threadGroups: [TimelineThreadGroup] = []
    public private(set) var isLoading = false
    public private(set) var isLoadingMore = false
    public private(set) var didFail = false
    public private(set) var paginationRevision = 0

    private let source: any TimelineSource
    private var cursor: String?
    private var consumedCursors: Set<String> = []
    private var hasLoaded = false
    private var contentGeneration = 0
    private var initialPageGeneration: Int?
    private var isEnriching = false
    private var visibleRefreshTask: Task<Void, Never>?
    private var visibleRefreshID: UUID?
    private var visibleRefreshWaiter: (UUID, CheckedContinuation<Void, Never>)?

    public init(source: any TimelineSource) {
        self.source = source
    }

    /// Changes when optional enrichment finishes, so a visible pagination sentinel
    /// can retry even when the last post's identity has not changed.
    public var canLoadMore: Bool {
        cursor != nil && !isLoading && !isLoadingMore && !isEnriching
    }

    public func load() async {
        guard !hasLoaded else { return }
        await replaceContent()
    }

    public func refresh() async {
        await replaceContent()
    }

    /// Completes the refresh gesture as soon as usable posts arrive. Optional
    /// enrichment remains owned by the model rather than the gesture's task.
    public func refreshVisibleContent() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                if let previous = visibleRefreshWaiter { finishVisibleRefresh(previous.0) }
                visibleRefreshTask?.cancel()
                // A superseded request can finish, but cannot publish over this one.
                contentGeneration += 1
                isLoading = false
                isLoadingMore = false
                isEnriching = false
                visibleRefreshID = id
                visibleRefreshWaiter = (id, continuation)
                visibleRefreshTask = Task { [weak self] in
                    guard let self else { return }
                    await self.replaceContent(onVisiblePage: { [weak self] in
                        self?.finishVisibleRefresh(id)
                    })
                    // Also release the waiter if another load won the guard
                    // before this queued task started.
                    self.finishVisibleRefresh(id)
                    if self.visibleRefreshID == id {
                        self.visibleRefreshTask = nil
                        self.visibleRefreshID = nil
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishVisibleRefresh(id) }
        }
    }

    private func finishVisibleRefresh(_ id: UUID) {
        guard visibleRefreshWaiter?.0 == id else { return }
        let continuation = visibleRefreshWaiter?.1
        visibleRefreshWaiter = nil
        continuation?.resume()
    }

    public func loadMore(after post: TimelinePost) async {
        guard let index = posts.firstIndex(where: { $0.id == post.id }),
              index >= max(posts.count - 5, 0),
              canLoadMore,
              let requestedCursor = cursor else { return }
        isLoadingMore = true
        let generation = contentGeneration
        defer { if generation == contentGeneration { isLoadingMore = false } }

        do {
            // Keep a pagination sentinel alive until its page is complete. An
            // early append changes the last-row identity and cancels that task.
            let page = try await source.timeline(cursor: requestedCursor, limit: 50)
            try Task.checkCancellation()
            guard generation == contentGeneration else { return }
            updateEnrichedPosts(page.posts)
            appendUnique(page.posts)
            consumedCursors.insert(requestedCursor)
            cursor = nextCursor(page.cursor)
            // Empty or duplicate-only pages can still advance the cursor. Wake
            // the visible sentinel even when the last post identity is unchanged.
            paginationRevision += 1
            didFail = false
        } catch is CancellationError {
        } catch {
            if generation == contentGeneration { didFail = true }
        }
    }

    public func retry() async {
        if posts.isEmpty {
            await replaceContent()
        } else if let last = posts.last {
            await loadMore(after: last)
        }
    }

    private func replaceContent(onVisiblePage: (@MainActor @Sendable () -> Void)? = nil) async {
        guard !isLoading else {
            onVisiblePage?()
            return
        }
        // A refresh replaces both the posts and their cursor. Pending older pages
        // may finish, but must not append to this new sequence or change its state.
        contentGeneration += 1
        consumedCursors.removeAll()
        isLoadingMore = false
        isLoading = true
        isEnriching = true
        didFail = false
        let generation = contentGeneration
        defer {
            if generation == contentGeneration {
                isLoading = false
                isEnriching = false
                paginationRevision += 1
            }
            onVisiblePage?()
        }

        do {
            let page = try await source.timeline(cursor: nil, limit: 50) { [weak self] page in
                await self?.receiveInitialPage(page, generation: generation, replacing: true, onVisiblePage: onVisiblePage)
            }
            try Task.checkCancellation()
            guard generation == contentGeneration else { return }
            if initialPageGeneration == generation {
                updateEnrichedPosts(page.posts)
            } else {
                posts = uniquePosts(page.posts)
            }
            cursor = nextCursor(page.cursor)
            hasLoaded = true
        } catch is CancellationError {
        } catch {
            if generation == contentGeneration { didFail = true }
        }
    }

    private func receiveInitialPage(
        _ page: TimelinePage, generation: Int, replacing: Bool,
        onVisiblePage: (@MainActor @Sendable () -> Void)? = nil
    ) {
        guard generation == contentGeneration, !Task.isCancelled else { return }
        if replacing {
            initialPageGeneration = generation
            posts = uniquePosts(page.posts)
            hasLoaded = true
            isLoading = false
        } else {
            appendUnique(page.posts)
        }
        cursor = nextCursor(page.cursor)
        onVisiblePage?()
    }

    private func updateEnrichedPosts(_ enriched: [TimelinePost]) {
        let byID = enriched.reduce(into: [String: TimelinePost]()) {
            if $0[$1.id] == nil { $0[$1.id] = $1 }
        }
        let updatedPosts = posts.map { byID[$0.id] ?? $0 }
        if updatedPosts != posts { posts = updatedPosts }
    }

    private func appendUnique(_ newPosts: [TimelinePost]) {
        var knownIDs = Set(posts.map(\.id))
        let uniquePosts = newPosts.filter { knownIDs.insert($0.id).inserted }
        if !uniquePosts.isEmpty { posts.append(contentsOf: uniquePosts) }
    }

    private func uniquePosts(_ candidates: [TimelinePost]) -> [TimelinePost] {
        var knownIDs = Set<String>()
        return candidates.filter { knownIDs.insert($0.id).inserted }
    }

    private func nextCursor(_ proposed: String?) -> String? {
        guard let proposed, !proposed.isEmpty, !consumedCursors.contains(proposed) else { return nil }
        return proposed
    }
}
