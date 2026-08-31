import Foundation
import SwiftData

enum ReaderSwiftDataStack {
    static func makeReaderContainer() throws -> ModelContainer {
        let schema = Schema([
            PersistedGatewayResponse.self,
            PersistedPublicationEntries.self,
            PersistedEntryDetail.self,
            PersistedWireFeedPage.self,
            PersistedWireEditionPage.self,
            PersistedWireItemDetail.self,
            PersistedCircleEditionPage.self,
            PersistedCircleItemDetail.self,
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
            PersistedWireFeedPage.self,
            PersistedWireEditionPage.self,
            PersistedWireItemDetail.self,
            PersistedCircleEditionPage.self,
            PersistedCircleItemDetail.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }
}
