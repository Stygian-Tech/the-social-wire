import Foundation

struct SidebarExpandedSnapshot: Equatable {
    var subscribedFeedExpanded: Bool
    var followingFeedExpanded: Bool
    var foldersSectionExpanded: Bool
    var publicationsSectionExpanded: Bool
    var expandedFolderRkeys: Set<String>

    static func `default`() -> Self {
        Self(
            subscribedFeedExpanded: false,
            followingFeedExpanded: false,
            foldersSectionExpanded: false,
            publicationsSectionExpanded: false,
            expandedFolderRkeys: []
        )
    }
}

enum SidebarExpandedKeysStorage {
    static let storageKey = "the-social-wire.sidebar-expanded-keys.v1"
    static let subscribedFeedKey = "__sidebar_feed:subscribed"
    static let followingFeedKey = "__sidebar_feed:following"
    static let foldersSectionKey = "__sidebar_sec:folders"
    static let publicationsSectionKey = "__sidebar_sec:publications"
    private static let folderExpandPrefix = "folder:"

    static func folderExpandKey(rkey: String) -> String {
        "\(folderExpandPrefix)\(rkey)"
    }

    static func rkeyFromFolderExpandKey(_ key: String) -> String? {
        guard key.hasPrefix(folderExpandPrefix) else { return nil }
        return String(key.dropFirst(folderExpandPrefix.count))
    }

    static func load(viewerDid: String) -> SidebarExpandedSnapshot {
        guard !viewerDid.isEmpty else { return .default() }
        let store = readStore()
        guard let keys = store[viewerDid] else { return .default() }

        var expandedFolderRkeys = Set<String>()
        for key in keys {
            if let rkey = rkeyFromFolderExpandKey(key) {
                expandedFolderRkeys.insert(rkey)
            }
        }

        return SidebarExpandedSnapshot(
            subscribedFeedExpanded: keys.contains(subscribedFeedKey),
            followingFeedExpanded: keys.contains(followingFeedKey),
            foldersSectionExpanded: keys.contains(foldersSectionKey),
            publicationsSectionExpanded: keys.contains(publicationsSectionKey),
            expandedFolderRkeys: expandedFolderRkeys
        )
    }

    static func save(viewerDid: String, snapshot: SidebarExpandedSnapshot) {
        guard !viewerDid.isEmpty else { return }

        var keys: [String] = []
        if snapshot.subscribedFeedExpanded {
            keys.append(subscribedFeedKey)
        }
        if snapshot.followingFeedExpanded {
            keys.append(followingFeedKey)
        }
        if snapshot.foldersSectionExpanded {
            keys.append(foldersSectionKey)
        }
        if snapshot.publicationsSectionExpanded {
            keys.append(publicationsSectionKey)
        }
        keys.append(contentsOf: snapshot.expandedFolderRkeys.map(folderExpandKey(rkey:)).sorted())

        var store = readStore()
        store[viewerDid] = keys
        writeStore(store)
    }

    static func migrateFolderExpandKey(
        viewerDid: String,
        oldRkey: String,
        newRkey: String
    ) {
        guard !viewerDid.isEmpty, oldRkey != newRkey else { return }

        var snapshot = load(viewerDid: viewerDid)
        guard snapshot.expandedFolderRkeys.contains(oldRkey) else { return }

        snapshot.expandedFolderRkeys.remove(oldRkey)
        snapshot.expandedFolderRkeys.insert(newRkey)
        save(viewerDid: viewerDid, snapshot: snapshot)
    }

    private typealias ExpandedKeysStore = [String: [String]]

    private static func readStore() -> ExpandedKeysStore {
        guard let raw = UserDefaults.standard.string(forKey: storageKey),
              let data = raw.data(using: .utf8),
              let store = try? JSONDecoder().decode(ExpandedKeysStore.self, from: data)
        else {
            return [:]
        }
        return store
    }

    private static func writeStore(_ store: ExpandedKeysStore) {
        guard let data = try? JSONEncoder().encode(store),
              let raw = String(data: data, encoding: .utf8)
        else {
            return
        }
        UserDefaults.standard.set(raw, forKey: storageKey)
    }
}
