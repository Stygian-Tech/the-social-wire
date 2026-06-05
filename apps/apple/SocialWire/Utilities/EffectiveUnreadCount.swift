import Foundation

enum EffectiveUnreadCount {
    static func countUnreadCachedEntries(
        entryIds: [String],
        isEntryRead: (String) -> Bool
    ) -> Int {
        var seen = Set<String>()
        var count = 0
        for entryId in entryIds where seen.insert(entryId).inserted {
            if !isEntryRead(entryId) {
                count += 1
            }
        }
        return count
    }

    static func countCachedReadEntries(
        entryIds: [String],
        isEntryRead: (String) -> Bool
    ) -> Int {
        var seen = Set<String>()
        var count = 0
        for entryId in entryIds where seen.insert(entryId).inserted {
            if isEntryRead(entryId) {
                count += 1
            }
        }
        return count
    }

    static func effectivePublicationUnreadCount(
        serverCount: Int,
        cachedEntryIds: [String],
        isEntryRead: (String) -> Bool,
        capRaiseToServerCount: Bool = true
    ) -> Int {
        guard !cachedEntryIds.isEmpty else { return serverCount }
        let cachedUnread = countUnreadCachedEntries(entryIds: cachedEntryIds, isEntryRead: isEntryRead)
        let cachedRead = countCachedReadEntries(entryIds: cachedEntryIds, isEntryRead: isEntryRead)
        let reconciled = max(cachedUnread, serverCount - cachedRead)
        if capRaiseToServerCount, serverCount > 0 {
            return min(reconciled, serverCount)
        }
        return reconciled
    }
}
