import Foundation

/// AppView unread baselines, reconciliation with reader cache, and section sum caches.
@MainActor
final class SidebarUnreadController {
    var unreadCountsByPublicationId: [String: Int] = [:]
    var cachedPriorityProjection: PublicationSidebarResponseDTO?

    private(set) var foldersSectionUnreadCount = 0
    private(set) var subscribedUnfolderedSectionUnreadCount = 0
    private(set) var folderUnreadCountsByRkey: [String: Int] = [:]
    private(set) var followingSectionUnreadCount = 0

    private var readRevision = 0
    private var cacheRevision = 0
    private var displayMemo: [String: Int] = [:]
    private var lastMemoReadRevision = -1
    private var lastMemoCacheRevision = -1

    func reset() {
        unreadCountsByPublicationId = [:]
        cachedPriorityProjection = nil
        foldersSectionUnreadCount = 0
        subscribedUnfolderedSectionUnreadCount = 0
        folderUnreadCountsByRkey = [:]
        followingSectionUnreadCount = 0
        invalidateDisplayMemo()
    }

    func bumpReadRevision() {
        readRevision += 1
        invalidateDisplayMemo()
    }

    func bumpCacheRevision() {
        cacheRevision += 1
        invalidateDisplayMemo()
    }

    private func invalidateDisplayMemo() {
        displayMemo.removeAll()
        lastMemoReadRevision = -1
        lastMemoCacheRevision = -1
    }

    /// Skip optimistic baseline delta when reconciliation via read map is sufficient.
    func shouldDeferBaselineDelta(
        publicationId: String,
        entryId: String,
        coordinator: ReaderCacheCoordinator?
    ) -> Bool {
        guard let coordinator else { return false }
        let cacheKeys = PublicationUnreadCountLookup.cacheKeys(for: publicationId)
        for cacheKey in cacheKeys {
            if let entries = try? coordinator.publicationEntries(cacheKey),
               entries.contains(where: { $0.entryId == entryId })
            {
                return true
            }
        }
        return false
    }

    func displayCount(
        publicationId: String,
        readAtByEntryId: [String: Date],
        coordinator: ReaderCacheCoordinator?
    ) -> Int {
        if lastMemoReadRevision != readRevision || lastMemoCacheRevision != cacheRevision {
            displayMemo.removeAll()
            lastMemoReadRevision = readRevision
            lastMemoCacheRevision = cacheRevision
        }
        if let memoized = displayMemo[publicationId] {
            return memoized
        }

        let serverCount = PublicationUnreadCountLookup.lookup(
            in: unreadCountsByPublicationId,
            publicationId: publicationId
        )
        guard serverCount > 0 else {
            displayMemo[publicationId] = 0
            return 0
        }
        let cachedEntryIds = PublicationUnreadCountLookup.distinctCachedEntryIds(
            coordinator: coordinator,
            publicationIds: [publicationId]
        )
        let value = EffectiveUnreadCount.effectivePublicationUnreadCount(
            serverCount: serverCount,
            cachedEntryIds: cachedEntryIds,
            isEntryRead: { readAtByEntryId[$0] != nil }
        )
        displayMemo[publicationId] = value
        return value
    }

    func adjustCount(publicationId: String, delta: Int) {
        guard delta != 0 else { return }
        var map = unreadCountsByPublicationId
        let current = PublicationUnreadCountLookup.lookup(in: map, publicationId: publicationId)
        let next = max(0, current + delta)
        PublicationUnreadCountLookup.store(next, for: publicationId, in: &map)
        unreadCountsByPublicationId = map

        if let projection = cachedPriorityProjection {
            cachedPriorityProjection = PublicationProjectionMapping.applyingUnreadCounts(
                to: projection,
                counts: [publicationId: next],
                replacePublicationIds: [publicationId]
            )
        }
        invalidateDisplayMemo()
    }

    func applyFetchedCounts(
        _ counts: [String: Int],
        publicationIds: [String]
    ) {
        if let projection = cachedPriorityProjection {
            cachedPriorityProjection = PublicationProjectionMapping.applyingUnreadCounts(
                to: projection,
                counts: counts,
                replacePublicationIds: publicationIds
            )
            unreadCountsByPublicationId = PublicationProjectionMapping.unreadCountsMap(
                from: cachedPriorityProjection!
            )
            invalidateDisplayMemo()
            return
        }

        var map = unreadCountsByPublicationId
        for publicationId in publicationIds {
            let count = PublicationUnreadCountLookup.lookup(in: counts, publicationId: publicationId)
            PublicationUnreadCountLookup.store(count, for: publicationId, in: &map)
        }
        unreadCountsByPublicationId = map
        invalidateDisplayMemo()
    }

    func refreshSectionSums(
        folders: [RepoRecord<FolderRecord>],
        folderMap: [String: [DiscoveredPublication]],
        subscribedUnfoldered: [DiscoveredPublication],
        following: [DiscoveredPublication],
        displayCount: (DiscoveredPublication) -> Int
    ) {
        func sumUnread(_ publications: [DiscoveredPublication]) -> Int {
            publications.reduce(0) { $0 + displayCount($1) }
        }

        subscribedUnfolderedSectionUnreadCount = sumUnread(subscribedUnfoldered)
        followingSectionUnreadCount = sumUnread(following)
        folderUnreadCountsByRkey = Dictionary(uniqueKeysWithValues: folders.map { folder in
            let rkey = rkey(from: folder.uri)
            let pubs = folderMap[rkey] ?? []
            return (rkey, sumUnread(pubs))
        })
        foldersSectionUnreadCount = folderUnreadCountsByRkey.values.reduce(0, +)
    }
}
