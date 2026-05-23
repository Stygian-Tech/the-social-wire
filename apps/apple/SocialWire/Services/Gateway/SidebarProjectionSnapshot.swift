import Foundation

/// Persisted sidebar projection for cache-first repeat visits (mirrors web React Query persist).
struct SidebarProjectionSnapshot: Codable, Sendable {
    let priority: PublicationSidebarResponseDTO
    let folderSections: [PublicationFolderSectionDTO]?
    let folderAllPublicationRows: [SidebarPublicationRowDTO]?

    static let cacheKeyPrefix = "v1/sidebar/projection/"
    static let maxPersistedPublicationRows = 250

    static func cacheKey(viewerDid: String) -> String {
        "\(cacheKeyPrefix)\(viewerDid)"
    }

    static func shouldPersist(_ projection: PublicationSidebarResponseDTO) -> Bool {
        !projection.viewerDid.isEmpty
            && !projection.refreshedAt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && projection.allPublicationRows.count <= maxPersistedPublicationRows
    }
}

enum SidebarProjectionSnapshotBuilder {
    static func folderPayload(
        folderSections: [PublicationFolderSectionDTO]?,
        allPublicationRows: [SidebarPublicationRowDTO]
    ) -> (sections: [PublicationFolderSectionDTO], rows: [SidebarPublicationRowDTO])? {
        guard let folderSections, !folderSections.isEmpty else { return nil }
        return (folderSections, allPublicationRows)
    }
}
