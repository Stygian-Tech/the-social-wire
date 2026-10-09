import Foundation

struct StandardReaderList: Codable, Identifiable, Hashable, Sendable {
    let uri: String
    let name: String
    let description: String?
    let creatorDid: String
    let publications: [String]
    let users: [String]
    let owned: Bool
    let saved: Bool

    var id: String { uri }
}

struct StandardReaderListsPage: Codable, Sendable {
    let lists: [StandardReaderList]
    let refreshedAt: String
    let creatorDid: String?
    let complete: Bool
}

enum BootstrapStreamEventKind: String, Codable, Sendable {
    case sidebarPriority
    case sidebarSection
    case unreadCounts
    case selectedPublication
    case entriesPage
    case sidebarFolders
    case lists
    case warning
    case error
    case done
}

struct BootstrapStreamEventDTO: Codable, Sendable {
    let kind: BootstrapStreamEventKind
    let sidebarPriority: PublicationSidebarResponseDTO?
    let sidebarSection: BootstrapSidebarSectionPayloadDTO?
    let unreadCounts: BootstrapUnreadCountsPayloadDTO?
    let selectedPublication: BootstrapSelectedPublicationPayloadDTO?
    let entriesPage: BootstrapEntriesPagePayloadDTO?
    let sidebarFolders: BootstrapSidebarFoldersPayloadDTO?
    let lists: StandardReaderListsPage?
    let warning: BootstrapMessagePayloadDTO?
    let error: BootstrapMessagePayloadDTO?
    let done: BootstrapDonePayloadDTO?
}

struct BootstrapUnreadCountsPayloadDTO: Codable, Sendable {
    let counts: [String: Int]
    let replacePublicationIds: [String]?
    let generation: Int64?
    let accuracy: String?
    let countedAt: String?
}

struct BootstrapSelectedPublicationPayloadDTO: Codable, Sendable {
    let publicationId: String
}

struct BootstrapEntriesPagePayloadDTO: Codable, Sendable {
    let publicationId: String
    let entries: [EntryListItem]
    let cursor: String?
    let source: BootstrapEvidenceSourceDTO
    let cachedAt: String?
    let expiresAt: String?
}

enum BootstrapEvidenceSourceDTO: String, Codable, Sendable {
    case liveProjection = "live_projection"
    case projectionCache = "projection_cache"
    case unavailable
}

struct BootstrapSidebarFoldersPayloadDTO: Codable, Sendable {
    let folderSections: [PublicationFolderSectionDTO]
    let allPublicationRows: [SidebarPublicationRowDTO]
}

struct BootstrapSidebarSectionPayloadDTO: Codable, Sendable {
    let sectionKey: String
    let folderRkey: String?
    let folderUri: String?
    let publications: [SidebarPublicationRowDTO]
    let unreadCounts: [String: Int]?
    let replacePublicationIds: [String]?
    let refreshedAt: String
    let sectionGeneration: Int64?
}

struct BootstrapMessagePayloadDTO: Codable, Sendable {
    let message: String
}

struct BootstrapDonePayloadDTO: Codable, Sendable {
    let refreshedAt: String
    let source: BootstrapEvidenceSourceDTO?
}

enum BootstrapStreamSelection {
    static func firstUnreadPublicationId(
        myPublications: [SidebarPublicationRowDTO],
        subscribedUnfoldered: [SidebarPublicationRowDTO],
        following: [SidebarPublicationRowDTO],
        unreadCounts: [String: Int]
    ) -> String? {
        for row in myPublications + subscribedUnfoldered + following {
            let count = unreadCounts[row.publicationId] ?? row.unreadCount ?? 0
            if count > 0 {
                return row.publicationId
            }
        }
        return nil
    }
}

enum BootstrapStreamNDJSON {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func parseLines(_ input: String) -> [BootstrapStreamEventDTO] {
        input
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return try? decoder.decode(BootstrapStreamEventDTO.self, from: Data(trimmed.utf8))
            }
    }
}
