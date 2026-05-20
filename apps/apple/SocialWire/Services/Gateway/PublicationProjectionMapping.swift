import Foundation

enum PublicationProjectionMapping {
    static func publicationPrefsMap(
        from rows: [PublicationPrefsDTO]
    ) -> [String: RepoRecord<PublicationPrefsRecord>] {
        var map: [String: RepoRecord<PublicationPrefsRecord>] = [:]
        for row in rows {
            let raw = row.value ?? [:]
            let folderId = raw["folderId"]?.string
            let sortOrder = raw["sortOrder"].flatMap { value -> Int? in
                if case .number(let n) = value { return Int(n) }
                return nil
            }
            let hidden: Bool? = {
                guard let value = raw["hidden"] else { return nil }
                if case .bool(let flag) = value { return flag }
                return nil
            }()
            let createdAt = raw["createdAt"]?.string ?? row.publicationId

            map[row.publicationId] = RepoRecord(
                uri: row.uri,
                cid: "",
                value: PublicationPrefsRecord(
                    type: PDSRecordService.publicationPrefs,
                    publicationId: row.publicationId,
                    folderId: folderId,
                    sortOrder: sortOrder,
                    hidden: hidden,
                    createdAt: createdAt
                )
            )
        }
        return map
    }

    static func folderMap(
        allRows: [DiscoveredPublication],
        myPublications: [DiscoveredPublication],
        followingTab: [DiscoveredPublication],
        publicationPrefs: [String: RepoRecord<PublicationPrefsRecord>]
    ) -> [String: [DiscoveredPublication]] {
        let myIds = Set(myPublications.map(\.publicationId))
        let followingIds = Set(followingTab.map(\.publicationId))
        var folderMap: [String: [DiscoveredPublication]] = [:]

        for publication in allRows {
            guard !myIds.contains(publication.publicationId) else { continue }
            guard !followingIds.contains(publication.publicationId) else { continue }
            guard let folderId = publicationPrefs[publication.publicationId]?.value.folderId?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !folderId.isEmpty
            else { continue }
            folderMap[folderId, default: []].append(publication)
        }
        return folderMap
    }
}

extension SidebarPublicationRowDTO {
    func toDiscoveredPublication() -> DiscoveredPublication {
        DiscoveredPublication(
            publicationId: publicationId,
            subscriptionPublicationId: subscriptionPublicationId,
            authorDid: authorDid,
            authorHandle: authorHandle ?? authorDid,
            title: title,
            iconUrl: iconUrl,
            avatarUrl: avatarUrl,
            discoveredAt: discoveredAt
        )
    }
}

extension PublicationSidebarResponseDTO {
    func scopesByPublicationId() -> [String: PublicationAppViewScopeDTO] {
        var scopes: [String: PublicationAppViewScopeDTO] = [:]
        for row in allPublicationRows + myPublications + subscribedUnfoldered + followingTabPublications {
            scopes[row.publicationId] = row.appViewScope
        }
        return scopes
    }
}
