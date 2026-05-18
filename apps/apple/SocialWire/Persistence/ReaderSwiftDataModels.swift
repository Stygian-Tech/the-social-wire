import Foundation
import SwiftData

@Model
final class PersistedGatewayResponse {
    @Attribute(.unique) var cacheKey: String
    var etagValue: String?
    var body: Data?
    var cachedAt: Date

    init(cacheKey: String, etagValue: String?, body: Data?, cachedAt: Date = Date()) {
        self.cacheKey = cacheKey
        self.etagValue = etagValue
        self.body = body
        self.cachedAt = cachedAt
    }
}

/// Cached entry-list slice for stale-while-revalidate (bounded eviction at coordinator level).
@Model
final class PersistedPublicationEntries {
    @Attribute(.unique) var publicationId: String
    var entriesPayload: Data
    var cachedAt: Date

    init(publicationId: String, entriesPayload: Data, cachedAt: Date = Date()) {
        self.publicationId = publicationId
        self.entriesPayload = entriesPayload
        self.cachedAt = cachedAt
    }
}

@Model
final class PersistedEntryDetail {
    @Attribute(.unique) var entryId: String
    var detailPayload: Data
    var cachedAt: Date

    init(entryId: String, detailPayload: Data, cachedAt: Date = Date()) {
        self.entryId = entryId
        self.detailPayload = detailPayload
        self.cachedAt = cachedAt
    }
}

enum ReaderSwiftDataStack {
    static func makeReaderContainer() throws -> ModelContainer {
        let schema = Schema([
            PersistedGatewayResponse.self,
            PersistedPublicationEntries.self,
            PersistedEntryDetail.self,
        ])
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw SocialWireError.badResponse("Application Support unavailable.")
        }
        let folder = appSupport.appendingPathComponent("SocialWire", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("reader-cache.store")
        let config = ModelConfiguration(schema: schema, url: url)
        return try ModelContainer(for: schema, configurations: [config])
    }

    static func inMemoryTestContainer() throws -> ModelContainer {
        let schema = Schema([
            PersistedGatewayResponse.self,
            PersistedPublicationEntries.self,
            PersistedEntryDetail.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }
}
