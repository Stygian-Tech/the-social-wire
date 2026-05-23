import Foundation
import Observation
import SwiftData

private let maxPersistedPublicationRows = 32
private let maxPersistedEntryDetailRows = 120
private let maxPersistedGatewayKeys = 48
private let maxStoredEntriesPerPublication = 120

enum ReaderCacheCoding {
    static let encoder = JSONEncoder()
    static let decoder = JSONDecoder()
}

/// SwiftUI-main-actor façade over the reader-cache **`ModelContext`**.
@Observable
@MainActor
final class ReaderCacheCoordinator {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Gateway blobs

    func gatewayCachedBody(for cacheKey: String) -> Data? {
        let key = Self.normalize(cacheKey)
        var descriptor = FetchDescriptor<PersistedGatewayResponse>()
        descriptor.fetchLimit = 1
        descriptor.predicate = #Predicate<PersistedGatewayResponse> { $0.cacheKey == key }
        return (try? modelContext.fetch(descriptor))?.first?.body
    }

    func gatewayETag(for cacheKey: String) -> String? {
        let key = Self.normalize(cacheKey)
        var descriptor = FetchDescriptor<PersistedGatewayResponse>()
        descriptor.fetchLimit = 1
        descriptor.predicate = #Predicate<PersistedGatewayResponse> { $0.cacheKey == key }
        return (try? modelContext.fetch(descriptor))?.first?.etagValue
    }

    func upsertGatewayResponse(cacheKey: String, etag: String?, body: Data?) throws {
        let key = Self.normalize(cacheKey)
        var descriptor = FetchDescriptor<PersistedGatewayResponse>()
        descriptor.fetchLimit = 1
        descriptor.predicate = #Predicate<PersistedGatewayResponse> { $0.cacheKey == key }
        let row = try modelContext.fetch(descriptor).first
        if let existing = row {
            existing.etagValue = etag
            existing.body = body
            existing.cachedAt = Date()
        } else {
            modelContext.insert(PersistedGatewayResponse(cacheKey: key, etagValue: etag, body: body))
        }
        try modelContext.save()
        try pruneGatewayResponsesIfNeeded()
    }

    func removeGatewayCachedResponse(for cacheKey: String) throws {
        let key = Self.normalize(cacheKey)
        var descriptor = FetchDescriptor<PersistedGatewayResponse>()
        descriptor.fetchLimit = 1
        descriptor.predicate = #Predicate<PersistedGatewayResponse> { $0.cacheKey == key }
        guard let existing = try modelContext.fetch(descriptor).first else { return }
        modelContext.delete(existing)
        try modelContext.save()
    }

    // MARK: - Publication lists

    func publicationEntries(_ publicationId: String) throws -> [EntryListItem]? {
        var descriptor = FetchDescriptor<PersistedPublicationEntries>()
        descriptor.fetchLimit = 1
        descriptor.predicate = #Predicate<PersistedPublicationEntries> { $0.publicationId == publicationId }
        guard let data = try modelContext.fetch(descriptor).first?.entriesPayload else { return nil }
        return try ReaderCacheCoding.decoder.decode([EntryListItem].self, from: data)
    }

    func upsertPublicationEntries(publicationId: String, entries: [EntryListItem]) throws {
        let limit = Swift.min(entries.count, maxStoredEntriesPerPublication)
        let clipped = Array(entries.prefix(limit))
        let blob = try ReaderCacheCoding.encoder.encode(clipped)
        var descriptor = FetchDescriptor<PersistedPublicationEntries>()
        descriptor.fetchLimit = 1
        descriptor.predicate = #Predicate<PersistedPublicationEntries> { $0.publicationId == publicationId }
        if let existing = try modelContext.fetch(descriptor).first {
            existing.entriesPayload = blob
            existing.cachedAt = Date()
        } else {
            modelContext.insert(
                PersistedPublicationEntries(publicationId: publicationId, entriesPayload: blob)
            )
        }
        try modelContext.save()
        try prunePublicationRowsIfNeeded()
    }

    // MARK: - Entry detail

    func entryDetail(_ entryId: String) throws -> EntryDetail? {
        var descriptor = FetchDescriptor<PersistedEntryDetail>()
        descriptor.fetchLimit = 1
        descriptor.predicate = #Predicate<PersistedEntryDetail> { $0.entryId == entryId }
        guard let blob = try modelContext.fetch(descriptor).first?.detailPayload else { return nil }
        return try ReaderCacheCoding.decoder.decode(EntryDetail.self, from: blob)
    }

    func upsertEntryDetail(_ detail: EntryDetail) throws {
        let blob = try ReaderCacheCoding.encoder.encode(detail)
        var descriptor = FetchDescriptor<PersistedEntryDetail>()
        descriptor.fetchLimit = 1
        descriptor.predicate = #Predicate<PersistedEntryDetail> { $0.entryId == detail.entryId }
        if let existing = try modelContext.fetch(descriptor).first {
            existing.detailPayload = blob
            existing.cachedAt = Date()
        } else {
            modelContext.insert(PersistedEntryDetail(entryId: detail.entryId, detailPayload: blob))
        }
        try modelContext.save()
        try pruneEntryDetailsIfNeeded()
    }

    /// Unread count for **`publicationId`** from cached lists + timestamps (best-effort).
    func unreadCachedCount(publicationId: String, readAtByEntryId: [String: Date]) -> Int {
        guard let cached = try? publicationEntries(publicationId) else { return 0 }
        return cached.filter { readAtByEntryId[$0.entryId] == nil }.count
    }

    /// Distinct entry ids from persisted publication lists (mirrors web **`distinctCachedEntryIdsForPublications`**).
    func distinctCachedEntryIds(publicationIds: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for publicationId in publicationIds {
            guard let cached = try? publicationEntries(publicationId) else { continue }
            for item in cached where seen.insert(item.entryId).inserted {
                ordered.append(item.entryId)
            }
        }
        return ordered
    }

    // MARK: - Pruning

    private func prunePublicationRowsIfNeeded() throws {
        var descriptor = FetchDescriptor<PersistedPublicationEntries>()
        descriptor.sortBy = [.init(\.cachedAt)]
        let rows = try modelContext.fetch(descriptor)
        guard rows.count > maxPersistedPublicationRows else { return }

        rows.sorted { $0.cachedAt > $1.cachedAt }
            .dropFirst(maxPersistedPublicationRows)
            .forEach { modelContext.delete($0) }
        try modelContext.save()
    }

    private func pruneEntryDetailsIfNeeded() throws {
        var descriptor = FetchDescriptor<PersistedEntryDetail>()
        descriptor.sortBy = [.init(\.cachedAt)]
        let rows = try modelContext.fetch(descriptor)
        guard rows.count > maxPersistedEntryDetailRows else { return }

        rows.sorted { $0.cachedAt > $1.cachedAt }
            .dropFirst(maxPersistedEntryDetailRows)
            .forEach { modelContext.delete($0) }
        try modelContext.save()
    }

    private func pruneGatewayResponsesIfNeeded() throws {
        var descriptor = FetchDescriptor<PersistedGatewayResponse>()
        descriptor.sortBy = [.init(\.cachedAt)]
        let rows = try modelContext.fetch(descriptor)
        guard rows.count > maxPersistedGatewayKeys else { return }

        rows.sorted { $0.cachedAt > $1.cachedAt }
            .dropFirst(maxPersistedGatewayKeys)
            .forEach { modelContext.delete($0) }
        try modelContext.save()
    }

    private static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
