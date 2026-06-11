import Foundation

enum PublicationSidebarTab: String, CaseIterable, Identifiable {
    case subscribed = "Subscribed"
    case following = "Following"

    var id: String { rawValue }
}

private let publicationRecordCollections: Set<String> = [
    "site.standard.publication",
    "com.standard.publication",
]

func normalizeDidForOwnershipCompare(_ raw: String) -> String {
    let trimmed = normalizeATRepoParam(raw)
    if trimmed.lowercased().hasPrefix("did:plc:") {
        return trimmed.lowercased()
    }
    return trimmed
}

/// Repo DID that owns this sidebar publication key (aggregate `did:…` id or a publication AT-URI).
func publicationRepoDid(_ publicationId: String) -> String {
    let normalized = normalizeATRepoParam(publicationId)
    if let at = ATURI(normalized),
       publicationRecordCollections.contains(at.collection)
    {
        return at.repo
    }
    if let at = ATURI(normalized) {
        return at.repo
    }
    return normalized
}

/// True if this discovered publication should appear only under My Publications, not subscribed sidebar lists.
func viewerOwnsDiscoveredPublication(
    _ publication: DiscoveredPublication,
    viewerDid: String?
) -> Bool {
    guard let viewerDid else { return false }
    let viewer = normalizeDidForOwnershipCompare(viewerDid)
    if normalizeDidForOwnershipCompare(publicationRepoDid(publication.publicationId)) == viewer {
        return true
    }
    if normalizeDidForOwnershipCompare(publication.authorDid) == viewer {
        return true
    }
    return false
}

func addPublicationSubscriptionLookupKeys(into keys: inout Set<String>, value: String?) {
    guard let value else { return }
    let normalized = normalizeATRepoParam(value)

    if normalized.hasPrefix("did:") {
        keys.insert(normalized)
        return
    }

    guard let at = ATURI(normalized) else { return }

    keys.insert(normalized)
    if at.collection == "site.standard.publication" {
        keys.insert("at://\(at.repo)/com.standard.publication/\(at.rkey)")
    } else if at.collection == "com.standard.publication" {
        keys.insert("at://\(at.repo)/site.standard.publication/\(at.rkey)")
    }
}

func publicationSubscriptionMatchKeys(for publication: DiscoveredPublication) -> [String] {
    var keys = Set<String>()
    addPublicationSubscriptionLookupKeys(into: &keys, value: publication.subscriptionPublicationId)
    addPublicationSubscriptionLookupKeys(into: &keys, value: publication.publicationId)
    return Array(keys)
}

func subscriptionPublicationKeys(from subscriptions: [RepoRecord<PublicationSubscriptionRecord>]) -> Set<String> {
    var keys = Set<String>()
    for subscription in subscriptions {
        addPublicationSubscriptionLookupKeys(into: &keys, value: subscription.value.publication)
    }
    return keys
}

func isSubscribedPublication(
    _ publication: DiscoveredPublication,
    subscriptionKeys: Set<String>
) -> Bool {
    publicationSubscriptionMatchKeys(for: publication).contains { subscriptionKeys.contains($0) }
}

/// Segments discovery rows into graph-subscribed vs follow-owned unsubscribed (mirror web `usePublicationSidebarData`).
func segmentDiscoveryPublications(
    _ discovered: [DiscoveredPublication],
    viewerDid: String?,
    subscriptionKeys: Set<String>
) -> (graphSubscribed: [DiscoveredPublication], followOwnedUnsubscribed: [DiscoveredPublication]) {
    guard let viewerDid else {
        return ([], [])
    }

    var graphSubscribed: [DiscoveredPublication] = []
    var followOwnedUnsubscribed: [DiscoveredPublication] = []

    for pub in discovered {
        if viewerOwnsDiscoveredPublication(pub, viewerDid: viewerDid) {
            graphSubscribed.append(pub)
        } else if isSubscribedPublication(pub, subscriptionKeys: subscriptionKeys) {
            graphSubscribed.append(pub)
        } else {
            followOwnedUnsubscribed.append(pub)
        }
    }

    return (graphSubscribed, followOwnedUnsubscribed)
}

func mergeSubscribedPublications(
    graphSubscribed: [DiscoveredPublication],
    rssPublications: [DiscoveredPublication]
) -> [DiscoveredPublication] {
    var merged = graphSubscribed
    var ids = Set(graphSubscribed.map(\.publicationId))
    for rss in rssPublications where !ids.contains(rss.publicationId) {
        merged.append(rss)
        ids.insert(rss.publicationId)
    }
    return merged
}

func filterFollowingTabPublications(
    followOwnedUnsubscribed: [DiscoveredPublication],
    myPublications: [DiscoveredPublication]
) -> [DiscoveredPublication] {
    let myIds = Set(myPublications.map(\.publicationId))
    return followOwnedUnsubscribed.filter { !myIds.contains($0.publicationId) }
}

func sumUnreadCount(
    for publications: [DiscoveredPublication],
    unreadCount: (DiscoveredPublication) -> Int
) -> Int {
    publications.reduce(0) { $0 + unreadCount($1) }
}

/// Unread-count map keys (mirrors web `lookupUnreadCountInMap` — normalized equality only).
enum PublicationUnreadCountLookup {
    static func publicationIdsMatch(_ lhs: String, _ rhs: String) -> Bool {
        normalizeATRepoParam(lhs) == normalizeATRepoParam(rhs)
    }

    static func lookup(in map: [String: Int], publicationId: String) -> Int {
        let target = normalizeATRepoParam(publicationId)
        for (key, count) in map where normalizeATRepoParam(key) == target {
            return count
        }
        return map[publicationId] ?? 0
    }

    static func remove(for publicationId: String, from map: inout [String: Int]) {
        let target = normalizeATRepoParam(publicationId)
        for key in map.keys where normalizeATRepoParam(key) == target {
            map.removeValue(forKey: key)
        }
    }

    static func store(_ count: Int, for publicationId: String, in map: inout [String: Int]) {
        remove(for: publicationId, from: &map)
        if count > 0 {
            map[normalizeATRepoParam(publicationId)] = count
        }
    }

    static func cacheKeys(for publicationId: String) -> [String] {
        var keys = Set<String>()
        keys.insert(publicationId)
        keys.insert(normalizeATRepoParam(publicationId))
        if let canonical = canonicalPublicationAtUriKey(publicationId) {
            keys.insert(canonical)
        }
        return Array(keys)
    }

    @MainActor
    static func distinctCachedEntryIds(
        coordinator: ReaderCacheCoordinator?,
        publicationIds: [String]
    ) -> [String] {
        guard let coordinator else { return [] }
        var cacheKeys = Set<String>()
        for publicationId in publicationIds {
            for key in cacheKeys(for: publicationId) {
                cacheKeys.insert(key)
            }
        }
        return coordinator.distinctCachedEntryIds(publicationIds: Array(cacheKeys))
    }
}
