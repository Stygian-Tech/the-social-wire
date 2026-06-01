import Foundation

@MainActor
final class PDSRecordService {
    nonisolated static let folder = "app.thesocialwire.folder"
    nonisolated static let publicationPrefs = "app.thesocialwire.publicationPrefs"
    nonisolated static let preferences = "app.thesocialwire.preferences"
    nonisolated static let standardSiteSubscription = "site.standard.graph.subscription"
    nonisolated static let skyreaderFeedSubscription = "app.skyreader.feed.subscription"
    nonisolated static let latrSavedExternal = "com.latr.saved.external"
    nonisolated static let latrSavedItem = "com.latr.saved.item"
    nonisolated static let entryReadState = "app.thesocialwire.entryReadState"

    nonisolated static let legacyFolder = "com.thesocialwire.folder"
    nonisolated static let legacyPublicationPrefs = "com.thesocialwire.publicationPrefs"
    nonisolated static let legacyPreferences = "com.thesocialwire.preferences"
    nonisolated static let legacyEntryReadState = "com.thesocialwire.entryReadState"

    nonisolated private static let preferencesRKey = "self"

    private let xrpc: XRPCClient

    init(xrpc: XRPCClient) {
        self.xrpc = xrpc
    }

    func listFolders() async throws -> [RepoRecord<FolderRecord>] {
        let page: ListRecordsResponse<FolderRecord> = try await xrpc.listRecords(repo: "", collection: Self.folder, authorized: true)
        return page.records.sorted { ($0.value.sortOrder ?? 0, $0.value.name) < ($1.value.sortOrder ?? 0, $1.value.name) }
    }

    func createFolder(name: String) async throws {
        let record = FolderRecord(type: Self.folder, name: name, sortOrder: 0, createdAt: DateFormatters.string())
        try await xrpc.createRecord(collection: Self.folder, record: record)
    }

    func deleteFolder(rkey: String) async throws {
        try await xrpc.deleteRecord(collection: Self.folder, rkey: rkey)
    }

    func listPublicationPrefs() async throws -> [RepoRecord<PublicationPrefsRecord>] {
        let page: ListRecordsResponse<PublicationPrefsRecord> = try await xrpc.listRecords(repo: "", collection: Self.publicationPrefs, authorized: true)
        return page.records
    }

    func upsertPublicationPrefs(publicationId: String, folderId: String?, existing: RepoRecord<PublicationPrefsRecord>?) async throws {
        let record = PublicationPrefsRecord(
            type: Self.publicationPrefs,
            publicationId: publicationId,
            folderId: folderId ?? existing?.value.folderId,
            sortOrder: existing?.value.sortOrder ?? 0,
            hidden: false,
            createdAt: existing?.value.createdAt ?? DateFormatters.string()
        )
        try await xrpc.putRecord(collection: Self.publicationPrefs, rkey: existing.map { rkey(from: $0.uri) } ?? DeterministicKeys.generateTID(), record: record)
    }

    func listPublicationSubscriptions() async throws -> [RepoRecord<PublicationSubscriptionRecord>] {
        let page: ListRecordsResponse<PublicationSubscriptionRecord> = try await xrpc.listRecords(repo: "", collection: Self.standardSiteSubscription, authorized: true)
        return page.records
    }

    func createPublicationSubscription(publication: String) async throws {
        try await xrpc.createRecord(
            collection: Self.standardSiteSubscription,
            record: PublicationSubscriptionRecord(type: Self.standardSiteSubscription, publication: publication)
        )
    }

    func listSkyreaderSubscriptions() async throws -> [RepoRecord<SkyreaderFeedSubscriptionRecord>] {
        let page: ListRecordsResponse<SkyreaderFeedSubscriptionRecord> = try await xrpc.listRecords(repo: "", collection: Self.skyreaderFeedSubscription, authorized: true)
        return page.records
    }

    func createSkyreaderSubscription(feedURL: String, title: String?) async throws {
        let now = DateFormatters.string()
        let record = SkyreaderFeedSubscriptionRecord(
            type: Self.skyreaderFeedSubscription,
            createdAt: now,
            updatedAt: now,
            feedUrl: feedURL,
            title: title,
            siteUrl: URL(string: feedURL)?.host.map { "https://\($0)" },
            source: "the-social-wire",
            sourceType: "rss"
        )
        try await xrpc.createRecord(collection: Self.skyreaderFeedSubscription, record: record)
    }

    func listEntryReadStates() async throws -> [String: Date] {
        let page: ListRecordsResponse<EntryReadStateRecord> = try await xrpc.listRecords(repo: "", collection: Self.entryReadState, authorized: true)
        var out: [String: Date] = [:]
        for record in page.records {
            guard let date = DateFormatters.date(from: record.value.readAt) else { continue }
            let existing = out[record.value.subjectUri]
            out[record.value.subjectUri] = min(existing ?? date, date)
        }
        return out
    }

    func markRead(subjectURI: String, readAt: Date = Date()) async throws {
        let now = DateFormatters.string(from: readAt)
        let record = EntryReadStateRecord(type: Self.entryReadState, subjectUri: subjectURI, readAt: now, updatedAt: DateFormatters.string())
        try await xrpc.putRecord(collection: Self.entryReadState, rkey: DeterministicKeys.entryReadStateRKey(subjectURI: subjectURI), record: record)
    }

    func markUnread(subjectURI: String) async throws {
        try await xrpc.deleteRecord(collection: Self.entryReadState, rkey: DeterministicKeys.entryReadStateRKey(subjectURI: subjectURI))
    }

    func getPreferences() async throws -> RepoRecord<PreferencesRecord>? {
        try await xrpc.authorizedRepoGetRecord(collection: Self.preferences, rkey: Self.preferencesRKey)
    }

    func upsertReadLaterServicePreference(_ serviceId: String) async throws {
        let current = try await getPreferences()
        let prev = current?.value
        let now = DateFormatters.string()
        let record = PreferencesRecord(
            type: Self.preferences,
            readLaterService: serviceId,
            readLaterConnections: prev?.readLaterConnections,
            createdAt: prev?.createdAt ?? now,
            updatedAt: now
        )
        try await xrpc.putRecord(collection: Self.preferences, rkey: Self.preferencesRKey, record: record)
    }

    func listMergedLatrSaves(
        state: LatrSaveListState = .active,
        latrGateway: LatrGatewayClient? = nil
    ) async throws -> [MergedLatrSave] {
        if let latrGateway {
            let items = try await latrGateway.listSavedItems()
            return Self.filterMergedLatrSavesByState(
                Self.mergeFromGatewayItems(items),
                state: state
            )
        }

        let externals: ListRecordsResponse<LatrSavedExternalRecord> = try await xrpc.listRecords(repo: "", collection: Self.latrSavedExternal, authorized: true)
        let items: ListRecordsResponse<LatrSavedItemRecord> = try await xrpc.listRecords(repo: "", collection: Self.latrSavedItem, authorized: true)
        return Self.filterMergedLatrSavesByState(
            Self.merge(externals: externals.records, items: items.records),
            state: state
        )
    }

    func saveURLToLatr(_ url: URL, title: String?) async throws {
        let normalized = PublicURLNormalizer.normalizeHttpURLToHTTPS(url.absoluteString)
        let externalRkey = DeterministicKeys.latrExternalRKey(normalizedURL: normalized)
        let subjectURI = "at://\(try await currentDID())/\(Self.latrSavedExternal)/\(externalRkey)"
        let itemRkey = DeterministicKeys.latrItemRKey(subjectURI: subjectURI)
        let now = DateFormatters.string()
        let external = LatrSavedExternalRecord(
            type: Self.latrSavedExternal,
            url: normalized,
            normalizedUrl: normalized,
            fingerprint: DeterministicKeys.latrFingerprint(normalizedURL: normalized),
            createdAt: now,
            title: title,
            site: URL(string: normalized)?.host
        )
        let item = LatrSavedItemRecord(type: Self.latrSavedItem, subjectUri: subjectURI, savedAt: now, state: "unread")
        try await xrpc.putRecord(collection: Self.latrSavedExternal, rkey: externalRkey, record: external)
        try await xrpc.putRecord(collection: Self.latrSavedItem, rkey: itemRkey, record: item)
    }

    func archiveLatrExternal(normalizedURL: String) async throws {
        try await updateLatrExternalState(normalizedURL: normalizedURL, state: "archived")
    }

    func deleteLatrExternal(normalizedURL: String) async throws {
        let externalRkey = DeterministicKeys.latrExternalRKey(normalizedURL: normalizedURL)
        let subjectURI = "at://\(try await currentDID())/\(Self.latrSavedExternal)/\(externalRkey)"
        try await xrpc.deleteRecord(collection: Self.latrSavedItem, rkey: DeterministicKeys.latrItemRKey(subjectURI: subjectURI))
        try await xrpc.deleteRecord(collection: Self.latrSavedExternal, rkey: externalRkey)
    }

    private func updateLatrExternalState(normalizedURL: String, state: String) async throws {
        let externalRkey = DeterministicKeys.latrExternalRKey(normalizedURL: normalizedURL)
        let subjectURI = "at://\(try await currentDID())/\(Self.latrSavedExternal)/\(externalRkey)"
        let item = LatrSavedItemRecord(type: Self.latrSavedItem, subjectUri: subjectURI, savedAt: DateFormatters.string(), state: state)
        try await xrpc.putRecord(collection: Self.latrSavedItem, rkey: DeterministicKeys.latrItemRKey(subjectURI: subjectURI), record: item)
    }

    private func currentDID() async throws -> String {
        try await xrpc.currentDID()
    }

    nonisolated static func filterMergedLatrSavesByState(_ rows: [MergedLatrSave], state: LatrSaveListState) -> [MergedLatrSave] {
        rows.filter { row in
            let itemState = row.state ?? "unread"
            switch state {
            case .all:
                return true
            case .archived:
                return itemState == "archived"
            case .active:
                return itemState != "archived"
            }
        }
    }

    nonisolated static func mergeLatrSaveMetadata(
        external: LatrSavedExternalRecord?,
        item: LatrSavedItemRecord
    ) -> LatrSaveMetadata {
        func trimmed(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        return LatrSaveMetadata(
            title: trimmed(external?.title) ?? trimmed(item.previewTitle),
            excerpt: trimmed(external?.excerpt) ?? trimmed(item.previewExcerpt),
            image: trimmed(external?.image) ?? trimmed(item.previewImage),
            site: trimmed(external?.site) ?? trimmed(item.previewSite),
            author: trimmed(external?.author) ?? trimmed(item.previewAuthor),
            publishedAt: trimmed(external?.publishedAt),
            language: trimmed(external?.language),
            linkedWebUrl: trimmed(item.linkedWebUrl)
        )
    }

    nonisolated static func merge(externals: [RepoRecord<LatrSavedExternalRecord>], items: [RepoRecord<LatrSavedItemRecord>]) -> [MergedLatrSave] {
        let externalByRkey = Dictionary(uniqueKeysWithValues: externals.map { (rkey(from: $0.uri), $0) })
        let marker = "/\(Self.latrSavedExternal)/"
        var rows: [MergedLatrSave] = []

        for item in items {
            guard let markerRange = item.value.subjectUri.range(of: marker) else {
                let metadata = mergeLatrSaveMetadata(external: nil, item: item.value)
                rows.append(.native(MergedLatrNativeSave(
                    savedAt: item.value.savedAt,
                    itemRkey: rkey(from: item.uri),
                    itemUri: item.uri,
                    subjectUri: item.value.subjectUri,
                    state: item.value.state,
                    title: metadata.title,
                    excerpt: metadata.excerpt,
                    url: metadata.linkedWebUrl,
                    image: metadata.image,
                    site: metadata.site,
                    author: metadata.author,
                    publishedAt: metadata.publishedAt,
                    language: metadata.language,
                    linkedWebUrl: metadata.linkedWebUrl
                )))
                continue
            }
            let externalRkey = String(item.value.subjectUri[markerRange.upperBound...])
            guard let external = externalByRkey[externalRkey] else { continue }
            let metadata = mergeLatrSaveMetadata(external: external.value, item: item.value)
            rows.append(.external(MergedLatrExternalSave(
                normalizedUrl: external.value.normalizedUrl,
                url: external.value.url,
                savedAt: item.value.savedAt,
                externalRkey: externalRkey,
                itemRkey: rkey(from: item.uri),
                externalUri: external.uri,
                itemUri: item.uri,
                subjectUri: item.value.subjectUri,
                state: item.value.state,
                title: metadata.title,
                excerpt: metadata.excerpt,
                image: metadata.image,
                site: metadata.site,
                author: metadata.author,
                publishedAt: metadata.publishedAt,
                language: metadata.language,
                linkedWebUrl: metadata.linkedWebUrl
            )))
        }

        return rows.sorted { $0.savedAt > $1.savedAt }
    }

    nonisolated static func mergeFromGatewayItems(_ items: [RepoRecord<LatrSavedItemRecord>]) -> [MergedLatrSave] {
        let marker = "/\(Self.latrSavedExternal)/"
        var rows: [MergedLatrSave] = []

        for item in items {
            guard let markerRange = item.value.subjectUri.range(of: marker) else {
                let metadata = mergeLatrSaveMetadata(external: nil, item: item.value)
                rows.append(.native(MergedLatrNativeSave(
                    savedAt: item.value.savedAt,
                    itemRkey: rkey(from: item.uri),
                    itemUri: item.uri,
                    subjectUri: item.value.subjectUri,
                    state: item.value.state,
                    title: metadata.title,
                    excerpt: metadata.excerpt,
                    url: metadata.linkedWebUrl,
                    image: metadata.image,
                    site: metadata.site,
                    author: metadata.author,
                    publishedAt: metadata.publishedAt,
                    language: metadata.language,
                    linkedWebUrl: metadata.linkedWebUrl
                )))
                continue
            }

            let externalRkey = String(item.value.subjectUri[markerRange.upperBound...])
            let linked = item.value.linkedWebUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
            let metadata = mergeLatrSaveMetadata(external: nil, item: item.value)
            rows.append(.external(MergedLatrExternalSave(
                normalizedUrl: linked ?? item.value.subjectUri,
                url: linked ?? item.value.subjectUri,
                savedAt: item.value.savedAt,
                externalRkey: externalRkey,
                itemRkey: rkey(from: item.uri),
                externalUri: item.value.subjectUri,
                itemUri: item.uri,
                subjectUri: item.value.subjectUri,
                state: item.value.state,
                title: metadata.title,
                excerpt: metadata.excerpt,
                image: metadata.image,
                site: metadata.site,
                author: metadata.author,
                publishedAt: metadata.publishedAt,
                language: metadata.language,
                linkedWebUrl: metadata.linkedWebUrl
            )))
        }

        return rows.sorted { $0.savedAt > $1.savedAt }
    }
}
