import Foundation

enum OptimisticSidebarMutation {
    static let optimisticFolderRkeyPrefix = "optimistic-folder-"

    static func createOptimisticFolderRkey() -> String {
        "\(optimisticFolderRkeyPrefix)\(UUID().uuidString.lowercased())"
    }

    static func isOptimisticFolderRkey(_ rkey: String) -> Bool {
        rkey.hasPrefix(optimisticFolderRkeyPrefix)
    }

    static func addOptimisticFolder(
        folders: inout [RepoRecord<FolderRecord>],
        folderMap: inout [String: [DiscoveredPublication]],
        viewerDid: String,
        rkey: String,
        name: String
    ) {
        let sortOrder = (folders.map(\.value.sortOrder).compactMap { $0 }.max() ?? -1) + 1
        let createdAt = ISO8601DateFormatter().string(from: Date())
        let uri = "at://\(viewerDid)/\(PDSRecordService.folder)/\(rkey)"
        let folder = RepoRecord(
            uri: uri,
            cid: "",
            value: FolderRecord(
                type: PDSRecordService.folder,
                name: name,
                sortOrder: sortOrder,
                icon: nil,
                iconImage: nil,
                createdAt: createdAt
            )
        )
        folders.append(folder)
        folders.sort { ($0.value.sortOrder ?? 0, $0.value.name) < ($1.value.sortOrder ?? 0, $1.value.name) }
        folderMap[rkey] = []
    }

    static func replaceOptimisticFolder(
        folders: inout [RepoRecord<FolderRecord>],
        folderMap: inout [String: [DiscoveredPublication]],
        publicationPrefs: inout [String: RepoRecord<PublicationPrefsRecord>],
        optimisticRkey: String,
        created: GatewayRecordWriteResponseDTO,
        name: String
    ) {
        guard let index = folders.firstIndex(where: { rkey(from: $0.uri) == optimisticRkey }) else { return }
        let existing = folders[index]
        let folder = RepoRecord(
            uri: created.uri,
            cid: "",
            value: FolderRecord(
                type: PDSRecordService.folder,
                name: name,
                sortOrder: existing.value.sortOrder,
                icon: existing.value.icon,
                iconImage: existing.value.iconImage,
                createdAt: existing.value.createdAt
            )
        )
        folders[index] = folder

        if let publications = folderMap.removeValue(forKey: optimisticRkey) {
            folderMap[created.rkey] = publications
        } else {
            folderMap[created.rkey] = []
        }

        for (publicationId, pref) in publicationPrefs {
            guard pref.value.folderId == optimisticRkey else { continue }
            var value = pref.value
            value.folderId = created.rkey
            publicationPrefs[publicationId] = RepoRecord(uri: pref.uri, cid: pref.cid, value: value)
        }
    }

    static func removeFolder(
        folders: inout [RepoRecord<FolderRecord>],
        folderMap: inout [String: [DiscoveredPublication]],
        subscribedUnfoldered: inout [DiscoveredPublication],
        publicationPrefs: inout [String: RepoRecord<PublicationPrefsRecord>],
        folderRkey: String
    ) {
        let restored = folderMap.removeValue(forKey: folderRkey) ?? []
        folders.removeAll { rkey(from: $0.uri) == folderRkey }

        let restoredIds = Set(restored.map(\.publicationId))
        subscribedUnfoldered.removeAll { restoredIds.contains($0.publicationId) }
        subscribedUnfoldered.append(contentsOf: restored)

        for (publicationId, pref) in publicationPrefs {
            guard pref.value.folderId == folderRkey else { continue }
            var value = pref.value
            value.folderId = nil
            publicationPrefs[publicationId] = RepoRecord(uri: pref.uri, cid: pref.cid, value: value)
        }
    }

    static func movePublication(
        publication: DiscoveredPublication,
        toFolderRkey: String?,
        subscribedUnfoldered: inout [DiscoveredPublication],
        folderMap: inout [String: [DiscoveredPublication]],
        publicationPrefs: inout [String: RepoRecord<PublicationPrefsRecord>],
        myPublicationIds: Set<String>,
        followingPublicationIds: Set<String>
    ) {
        subscribedUnfoldered.removeAll { $0.publicationId == publication.publicationId }
        for key in folderMap.keys {
            folderMap[key]?.removeAll { $0.publicationId == publication.publicationId }
        }

        if let folderRkey = toFolderRkey {
            var folderPubs = folderMap[folderRkey] ?? []
            if !folderPubs.contains(where: { $0.publicationId == publication.publicationId }) {
                folderPubs.append(publication)
            }
            folderMap[folderRkey] = folderPubs
        } else if !myPublicationIds.contains(publication.publicationId),
                  !followingPublicationIds.contains(publication.publicationId),
                  !subscribedUnfoldered.contains(where: { $0.publicationId == publication.publicationId })
        {
            subscribedUnfoldered.append(publication)
        }

        if let existing = publicationPrefs[publication.publicationId] {
            var value = existing.value
            value.folderId = toFolderRkey
            publicationPrefs[publication.publicationId] = RepoRecord(
                uri: existing.uri,
                cid: existing.cid,
                value: value
            )
        }
    }
}
