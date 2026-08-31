import Foundation

/// Authenticated calls to **`SocialWireAPIEnvironment.baseURL`** (DPoP + access JWT), mirroring PDS **`XRPCClient`** semantics.
@MainActor
final class SocialWireGatewayClient {
    private struct EmptyXRPCInput: Encodable {}

    private struct CircleHiddenItemInput: Encodable {
        let storyId: String
        let hidden: Bool
    }

    private let auth: ATProtoOAuthService
    private let baseURL: URL
    private let urlSession: URLSession

    nonisolated static let wireViewerModerationNSIDs = [
        "app.bsky.actor.getPreferences",
        "app.bsky.graph.getBlocks",
        "app.bsky.graph.getMutes",
        "app.bsky.graph.getListMutes",
        "app.bsky.graph.getListBlocks",
    ]

    nonisolated static let circleViewerGraphNSIDs = wireViewerModerationNSIDs + [
        "com.atproto.repo.listRecords",
    ]

    nonisolated static let wireModerationDPoPHeader = "X-Wire-Moderation-DPoP"
    nonisolated static let circleGraphDPoPHeader = "X-Circle-Graph-DPoP"

    nonisolated static func wireQuery(
        language: String,
        cursor: String?,
        limit: Int
    ) -> [String: String] {
        var query = [
            "lang": language,
            "limit": String(limit),
        ]
        if let cursor, !cursor.isEmpty {
            query["cursor"] = cursor
        }
        return query
    }

    nonisolated static func wireEditionQuery(
        language: String?,
        region: WireViewerRegion?,
        cursor: String? = nil
    ) -> [String: String] {
        var query: [String: String] = [:]
        if let language, !language.isEmpty {
            query["lang"] = language
        }
        if let region {
            query["region"] = region.rawValue
        }
        if let cursor, !cursor.isEmpty {
            query["cursor"] = cursor
        }
        return query
    }

    nonisolated static func circleEditionQuery(
        language: String?,
        cursor: String?
    ) -> [String: String] {
        var query: [String: String] = [:]
        if let language, !language.isEmpty {
            query["lang"] = language
        }
        if let cursor, !cursor.isEmpty {
            query["cursor"] = cursor
        }
        return query
    }

    nonisolated static func requiresWireModerationProofs(path: String) -> Bool {
        path == SocialWireXRPCMethod.getWire
            || path == SocialWireXRPCMethod.getWireEdition
            || path == SocialWireXRPCMethod.getWireItem
    }

    nonisolated static func requiresCircleGraphProofs(path: String) -> Bool {
        path == SocialWireXRPCMethod.getCircleEdition
    }

    init(
        auth: ATProtoOAuthService,
        baseURL: URL = SocialWireAPIEnvironment.baseURL,
        urlSession: URLSession = .shared
    ) {
        self.auth = auth
        self.baseURL = baseURL
        self.urlSession = urlSession
    }

    func fetchSyncPreferences(ifNoneMatch: String?) async throws -> GatewayHTTPResult {
        try await authorizedGET(path: SocialWireXRPCMethod.getPreferences, query: [:], ifNoneMatch: ifNoneMatch)
    }

    func fetchSembleCollections(limit: Int = 100, cursor: String? = nil) async throws -> SembleCollectionPage {
        var query = ["limit": String(limit)]
        if let cursor, !cursor.isEmpty { query["cursor"] = cursor }
        let result = try await authorizedGET(
            path: "/v1/semble/collections",
            query: query,
            ifNoneMatch: nil
        )
        guard (200 ..< 300).contains(result.statusCode) else {
            throw SocialWireError.badResponse("Semble collections failed (\(result.statusCode)).")
        }
        return try JSONDecoder().decode(SembleCollectionPage.self, from: result.body)
    }

    func fetchSembleCollection(
        collectionURI: String,
        limit: Int = 100,
        cursor: String? = nil
    ) async throws -> SembleCollectionItemsPage {
        var query = ["collectionUri": collectionURI, "limit": String(limit)]
        if let cursor, !cursor.isEmpty { query["cursor"] = cursor }
        let result = try await authorizedGET(
            path: "/v1/semble/collection",
            query: query,
            ifNoneMatch: nil
        )
        if result.statusCode == 404 {
            throw SocialWireError.sembleCollectionUnavailable(
                "The selected Semble collection no longer exists."
            )
        }
        if result.statusCode == 403 {
            throw SocialWireError.sembleCollectionUnavailable(
                "You no longer own the selected Semble collection."
            )
        }
        guard (200 ..< 300).contains(result.statusCode) else {
            throw SocialWireError.badResponse("Semble collection failed (\(result.statusCode)).")
        }
        return try JSONDecoder().decode(SembleCollectionItemsPage.self, from: result.body)
    }

    func fetchSembleConnections(
        url: String,
        limit: Int = 100,
        cursor: String? = nil
    ) async throws -> SembleConnectionsPage {
        var query = ["url": url, "limit": String(limit)]
        if let cursor, !cursor.isEmpty { query["cursor"] = cursor }
        let result = try await authorizedGET(
            path: "/v1/semble/connections",
            query: query,
            ifNoneMatch: nil
        )
        guard (200 ..< 300).contains(result.statusCode) else {
            throw SocialWireError.badResponse("Semble connections failed (\(result.statusCode)).")
        }
        return try JSONDecoder().decode(SembleConnectionsPage.self, from: result.body)
    }

    func fetchCachedPdsRecord(collection: String, rkey: String, ifNoneMatch: String?) async throws -> GatewayHTTPResult {
        try await authorizedGET(
            path: "/v1/pds/cache/record",
            query: ["collection": collection, "rkey": rkey],
            ifNoneMatch: ifNoneMatch
        )
    }

    func fetchPublicationSidebar(
        phase: PublicationSidebarPhase = .full
    ) async throws -> PublicationSidebarResponseDTO {
        var query: [String: String] = [:]
        if phase != .full {
            query["phase"] = phase.rawValue
        }
        let result = try await authorizedGET(
            path: SocialWireXRPCMethod.getSidebar,
            query: query,
            ifNoneMatch: nil
        )
        guard (200 ..< 300).contains(result.statusCode) else {
            throw SocialWireError.badResponse("Publication sidebar failed (\(result.statusCode)).")
        }
        return try PublicationProjectionJSON.decoder.decode(
            PublicationSidebarResponseDTO.self,
            from: result.body
        )
    }

    func refreshPublicationSidebar() async throws -> PublicationSidebarResponseDTO {
        let payload = try JSONEncoder().encode(EmptyXRPCInput())
        let result = try await authorizedRequest(
            method: "POST",
            path: SocialWireXRPCMethod.refreshSidebar,
            query: [:],
            body: payload,
            contentType: "application/json"
        )
        guard (200 ..< 300).contains(result.statusCode) else {
            throw SocialWireError.badResponse("Publication refresh failed (\(result.statusCode)).")
        }
        return try PublicationProjectionJSON.decoder.decode(
            PublicationSidebarResponseDTO.self,
            from: result.body
        )
    }

    func resolveAddPublication(input: String) async throws -> ResolveAddPublicationResponseDTO {
        let payload = try JSONEncoder().encode(ResolveAddPublicationRequestBody(input: input))
        let result = try await authorizedRequest(
            method: "POST",
            path: SocialWireXRPCMethod.resolvePublication,
            query: [:],
            body: payload,
            contentType: "application/json"
        )
        guard (200 ..< 300).contains(result.statusCode) else {
            throw SocialWireError.badResponse("Publication resolve failed (\(result.statusCode)).")
        }
        return try JSONDecoder().decode(ResolveAddPublicationResponseDTO.self, from: result.body)
    }

    func fetchAppViewEntries(
        scope: PublicationAppViewScopeDTO,
        filter: ReaderFilter,
        cursor: String?,
        limit: Int = 50,
        maxEntries: Int? = nil
    ) async throws -> AppViewEntryListResponse {
        var query: [String: String] = [
            "authorDid": scope.authorDid,
            "filter": filter == .unread ? "unread" : "all",
            "limit": String(limit),
        ]
        if let maxEntries {
            query["maxEntries"] = String(maxEntries)
        } else if let cursor, !cursor.isEmpty {
            query["cursor"] = cursor
        }
        if let publicationAtUri = scope.publicationAtUri, !publicationAtUri.isEmpty {
            query["publicationAtUri"] = publicationAtUri
        }
        if !scope.publicationScopeAtUris.isEmpty {
            query["publicationScopeAtUris"] = scope.publicationScopeAtUris.joined(separator: ",")
        }
        if !scope.publicationSiteUrls.isEmpty {
            query["publicationSiteUrls"] = scope.publicationSiteUrls.joined(separator: ",")
        }

        let result = try await authorizedFeedGET(path: SocialWireXRPCMethod.listEntries, query: query)
        if result.statusCode == 404 {
            throw SocialWireError.appViewUnavailable
        }
        guard (200 ..< 300).contains(result.statusCode) else {
            throw appViewFeedError(result, fallback: "AppView entries failed")
        }
        return try JSONDecoder().decode(AppViewEntryListResponse.self, from: result.body)
    }

    func fetchAggregateAppViewFeed(
        kind: String,
        id: String? = nil,
        filter: ReaderFilter,
        cursor: String?,
        limit: Int = 50
    ) async throws -> AppViewEntryListResponse {
        var query: [String: String] = [
            "kind": kind,
            "filter": filter == .unread ? "unread" : "all",
            "limit": String(limit),
        ]
        if let id, !id.isEmpty { query["id"] = id }
        if let cursor, !cursor.isEmpty { query["cursor"] = cursor }
        let result = try await authorizedFeedGET(
            path: SocialWireXRPCMethod.getFeed,
            query: query
        )
        guard (200 ..< 300).contains(result.statusCode) else {
            throw appViewFeedError(result, fallback: "Aggregate AppView feed failed")
        }
        return try JSONDecoder().decode(AppViewEntryListResponse.self, from: result.body)
    }

    func fetchFeedCatalog() async throws -> WireFeedCatalog {
        let result = try await authorizedFeedGET(
            path: SocialWireXRPCMethod.getFeedCatalog,
            query: [:]
        )
        guard (200 ..< 300).contains(result.statusCode) else {
            throw appViewFeedError(result, fallback: "Feed catalog failed")
        }
        return try JSONDecoder().decode(WireFeedCatalog.self, from: result.body)
    }

    func fetchWire(
        language: String,
        cursor: String?,
        limit: Int = 50
    ) async throws -> WireFeedPage {
        let query = Self.wireQuery(language: language, cursor: cursor, limit: limit)
        let result = try await authorizedFeedGET(
            path: SocialWireXRPCMethod.getWire,
            query: query,
            includesWireModerationProofs: Self.requiresWireModerationProofs(
                path: SocialWireXRPCMethod.getWire
            )
        )
        guard (200 ..< 300).contains(result.statusCode) else {
            throw appViewFeedError(result, fallback: "The Wire failed")
        }
        return try JSONDecoder().decode(WireFeedPage.self, from: result.body)
    }

    func fetchWireEdition(
        language: String? = nil,
        region: WireViewerRegion? = nil,
        cursor: String? = nil
    ) async throws -> WireEditionPage {
        let result = try await authorizedFeedGET(
            path: SocialWireXRPCMethod.getWireEdition,
            query: Self.wireEditionQuery(
                language: language,
                region: region,
                cursor: cursor
            ),
            includesWireModerationProofs: Self.requiresWireModerationProofs(
                path: SocialWireXRPCMethod.getWireEdition
            )
        )
        guard (200 ..< 300).contains(result.statusCode) else {
            throw appViewFeedError(result, fallback: "The Wire edition failed")
        }
        return try JSONDecoder().decode(WireEditionPage.self, from: result.body)
    }

    func fetchWireItem(itemId: String) async throws -> WireFeedItemResponse {
        let result = try await authorizedFeedGET(
            path: SocialWireXRPCMethod.getWireItem,
            query: ["itemId": itemId],
            includesWireModerationProofs: Self.requiresWireModerationProofs(
                path: SocialWireXRPCMethod.getWireItem
            )
        )
        guard (200 ..< 300).contains(result.statusCode) else {
            throw appViewFeedError(result, fallback: "The Wire item failed")
        }
        return try JSONDecoder().decode(WireFeedItemResponse.self, from: result.body)
    }

    func fetchCircleCatalog() async throws -> CircleFeedCatalog {
        let result = try await authorizedFeedGET(
            path: SocialWireXRPCMethod.getCircleCatalog,
            query: [:]
        )
        guard (200 ..< 300).contains(result.statusCode) else {
            throw appViewFeedError(result, fallback: "Your Circle catalog failed")
        }
        return try JSONDecoder().decode(CircleFeedCatalog.self, from: result.body)
    }

    func fetchCircleEdition(
        language: String? = nil,
        cursor: String? = nil
    ) async throws -> CircleEditionPage {
        let result = try await authorizedFeedGET(
            path: SocialWireXRPCMethod.getCircleEdition,
            query: Self.circleEditionQuery(language: language, cursor: cursor),
            includesCircleGraphProofs: Self.requiresCircleGraphProofs(
                path: SocialWireXRPCMethod.getCircleEdition
            )
        )
        guard (200 ..< 300).contains(result.statusCode) else {
            throw appViewFeedError(result, fallback: "Your Circle edition failed")
        }
        return try JSONDecoder().decode(CircleEditionPage.self, from: result.body)
    }

    func setCircleItemHidden(storyId: String, hidden: Bool) async throws -> CircleHiddenItemState {
        let payload = try JSONEncoder().encode(
            CircleHiddenItemInput(storyId: storyId, hidden: hidden)
        )
        let result = try await authorizedRequest(
            method: "POST",
            path: SocialWireXRPCMethod.setCircleItemHidden,
            query: [:],
            body: payload,
            contentType: "application/json"
        )
        guard (200 ..< 300).contains(result.statusCode) else {
            throw appViewFeedError(result, fallback: "Your Circle hide state failed")
        }
        return try JSONDecoder().decode(CircleHiddenItemState.self, from: result.body)
    }

    func fetchAppViewEntryDetail(entryId: String) async throws -> EntryDetail? {
        let result = try await authorizedGET(
            path: SocialWireXRPCMethod.getEntry,
            query: ["entryId": entryId],
            ifNoneMatch: nil
        )
        if result.statusCode == 404 {
            return nil
        }
        guard (200 ..< 300).contains(result.statusCode) else {
            throw SocialWireError.badResponse("AppView entry detail failed (\(result.statusCode)).")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let dto = try decoder.decode(AppViewEntryDetailDTO.self, from: result.body)
        return dto.toEntryDetail()
    }

    func fetchAppViewUnreadCounts(publicationIds: [String]) async throws -> AppViewUnreadCountsResponse {
        guard !publicationIds.isEmpty else {
            return AppViewUnreadCountsResponse(
                counts: [:],
                generation: nil,
                accuracy: nil,
                countedAt: nil
            )
        }
        let result = try await authorizedGET(
            path: SocialWireXRPCMethod.getUnreadCounts,
            query: [:],
            repeatedQuery: ["publicationIds": publicationIds],
            ifNoneMatch: nil
        )
        if result.statusCode == 404 {
            return AppViewUnreadCountsResponse(
                counts: [:],
                generation: nil,
                accuracy: nil,
                countedAt: nil
            )
        }
        guard (200 ..< 300).contains(result.statusCode) else {
            throw SocialWireError.badResponse("AppView unread counts failed (\(result.statusCode)).")
        }
        return try JSONDecoder().decode(AppViewUnreadCountsResponse.self, from: result.body)
    }

    func upsertReadMark(subjectUri: String, readAt: Date) async throws {
        let payload = try JSONEncoder().encode(
            AppViewReadMarkBody(subjectUri: subjectUri, readAt: DateFormatters.string(from: readAt))
        )
        let result = try await authorizedRequest(
            method: "POST",
            path: SocialWireXRPCMethod.putReadMark,
            query: [:],
            body: payload,
            contentType: "application/json"
        )
        guard (200 ..< 300).contains(result.statusCode) else {
            throw SocialWireError.badResponse("AppView read-mark upsert failed (\(result.statusCode)).")
        }
    }

    func deleteReadMark(subjectUri: String) async throws {
        let payload = try JSONEncoder().encode(AppViewReadMarkDeleteBody(subjectUri: subjectUri))
        let result = try await authorizedRequest(
            method: "POST",
            path: SocialWireXRPCMethod.deleteReadMark,
            query: [:],
            body: payload,
            contentType: "application/json"
        )
        guard (200 ..< 300).contains(result.statusCode) else {
            throw SocialWireError.badResponse("AppView read-mark delete failed (\(result.statusCode)).")
        }
    }

    func markAllRead(scope: GatewayMarkAllReadScopeDTO) async throws -> GatewayMarkAllReadResponseDTO {
        let payload = try JSONEncoder().encode(GatewayMarkAllReadBody(scope: scope))
        let result = try await authorizedRequest(
            method: "POST",
            path: SocialWireXRPCMethod.markAllRead,
            query: [:],
            body: payload,
            contentType: "application/json"
        )
        if result.statusCode == 404 {
            throw SocialWireError.appViewUnavailable
        }
        guard (200 ..< 300).contains(result.statusCode) else {
            throw SocialWireError.badResponse("Mark all read failed (\(result.statusCode)).")
        }
        return try JSONDecoder().decode(GatewayMarkAllReadResponseDTO.self, from: result.body)
    }

    func enrollAuthors(dids: [String], feedUrls: [String] = []) async throws -> Int {
        let payload = try JSONEncoder().encode(AppViewEnrollBody(authorDids: dids, feedUrls: feedUrls))
        let result = try await authorizedRequest(
            method: "POST",
            path: SocialWireXRPCMethod.enrollSources,
            query: [:],
            body: payload,
            contentType: "application/json"
        )
        if result.statusCode == 404 {
            throw SocialWireError.appViewUnavailable
        }
        guard (200 ..< 300).contains(result.statusCode) else {
            throw SocialWireError.badResponse("AppView enroll failed (\(result.statusCode)).")
        }
        let decoded = try JSONDecoder().decode(AppViewEnrollResponse.self, from: result.body)
        return decoded.indexed
    }

    func purgeAppViewPrivacyData() async throws {
        let payload = try JSONEncoder().encode(EmptyXRPCInput())
        let result = try await authorizedRequest(
            method: "POST",
            path: SocialWireXRPCMethod.purgeViewerData,
            query: [:],
            body: payload,
            contentType: "application/json"
        )
        guard (200 ..< 300).contains(result.statusCode) else {
            throw SocialWireError.badResponse("AppView purge failed (\(result.statusCode)).")
        }
    }

    func consumeBootstrapStream(
        onEvent: @escaping @Sendable (BootstrapStreamEventDTO) -> Void
    ) async throws {
        guard let url = URL(string: "/v1/appview/bootstrap-stream", relativeTo: baseURL)?.absoluteURL else {
            throw SocialWireError.invalidURL
        }

        let session = try await auth.validSession()

        func authorizedStreamRequest() async throws -> URLRequest {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
            try await authorize(&request, session: session)
            return request
        }

        var (bytes, response) = try await urlSession.bytes(for: authorizedStreamRequest())
        guard var http = response as? HTTPURLResponse else {
            throw SocialWireError.badResponse("Missing gateway response.")
        }
        await captureNonces(from: http, session: session)

        // Cold-origin DPoP-nonce challenge: the server replies 401/400 with a fresh DPoP-Nonce when
        // the client hasn't seeded one yet. Re-authorize with that nonce and retry once (mirrors
        // authorizedRequest); otherwise a first-launch challenge would fail the whole bootstrap.
        if shouldRetryNonceChallenge(http) {
            (bytes, response) = try await urlSession.bytes(for: authorizedStreamRequest())
            guard let retryHttp = response as? HTTPURLResponse else {
                throw SocialWireError.badResponse("Missing gateway response.")
            }
            http = retryHttp
            await captureNonces(from: http, session: session)
        }

        guard (200 ..< 300).contains(http.statusCode) else {
            throw SocialWireError.badResponse("Bootstrap stream failed (\(http.statusCode)).")
        }

        for try await line in bytes.lines {
            try Self.consumeBootstrapLine(line, onEvent: onEvent)
        }
    }

    private static func consumeBootstrapLine(
        _ rawLine: String,
        onEvent: @escaping @Sendable (BootstrapStreamEventDTO) -> Void
    ) throws {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        let event = try BootstrapStreamNDJSON.decoder.decode(
            BootstrapStreamEventDTO.self,
            from: Data(line.utf8)
        )
        onEvent(event)
    }

    // MARK: - Private

    private func authorizedGET(
        path: String,
        query: [String: String],
        repeatedQuery: [String: [String]] = [:],
        ifNoneMatch: String?
    ) async throws -> GatewayHTTPResult {
        try await authorizedRequest(
            method: "GET",
            path: path,
            query: query,
            repeatedQuery: repeatedQuery,
            body: nil,
            contentType: nil,
            ifNoneMatch: ifNoneMatch
        )
    }

    private func authorizedFeedGET(
        path: String,
        query: [String: String],
        includesWireModerationProofs: Bool = false,
        includesCircleGraphProofs: Bool = false
    ) async throws -> GatewayHTTPResult {
        let first = try await authorizedRequest(
            method: "GET",
            path: path,
            query: query,
            body: nil,
            contentType: nil,
            includesWireModerationProofs: includesWireModerationProofs,
            includesCircleGraphProofs: includesCircleGraphProofs
        )
        guard !(200 ..< 300).contains(first.statusCode),
              let envelope = try? JSONDecoder().decode(AppViewErrorEnvelopeDTO.self, from: first.body),
              envelope.retryable
        else {
            return first
        }
        return try await authorizedRequest(
            method: "GET",
            path: path,
            query: query,
            body: nil,
            contentType: nil,
            includesWireModerationProofs: includesWireModerationProofs,
            includesCircleGraphProofs: includesCircleGraphProofs
        )
    }

    private func appViewFeedError(
        _ result: GatewayHTTPResult,
        fallback: String
    ) -> SocialWireError {
        if let envelope = try? JSONDecoder().decode(AppViewErrorEnvelopeDTO.self, from: result.body) {
            return .badResponse(
                "\(envelope.message) Request ID: \(envelope.requestId)"
            )
        }
        let requestId = result.requestIdHeader.map { " Request ID: \($0)" } ?? ""
        return .badResponse("\(fallback) (\(result.statusCode)).\(requestId)")
    }

    private func authorizedRequest(
        method: String,
        path: String,
        query: [String: String],
        repeatedQuery: [String: [String]] = [:],
        body: Data?,
        contentType: String?,
        ifNoneMatch: String? = nil,
        includesWireModerationProofs: Bool = false,
        includesCircleGraphProofs: Bool = false
    ) async throws -> GatewayHTTPResult {
        guard var comps = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw SocialWireError.invalidURL
        }
        if !query.isEmpty || !repeatedQuery.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
                + repeatedQuery.flatMap { key, values in
                    values.map { URLQueryItem(name: key, value: $0) }
                }
        }
        guard let url = comps.url else {
            throw SocialWireError.invalidURL
        }

        let session = try await auth.validSession()
        let wireModerationProofs = includesWireModerationProofs
            ? try await wireViewerModerationProofPool(session: session)
            : nil
        let circleGraphProofs = includesCircleGraphProofs
            ? try await circleViewerGraphProofPool(session: session)
            : nil
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
        }
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        try await authorize(&request, session: session)
        if let wireModerationProofs {
            request.setValue(wireModerationProofs, forHTTPHeaderField: Self.wireModerationDPoPHeader)
        }
        if let circleGraphProofs {
            request.setValue(circleGraphProofs, forHTTPHeaderField: Self.circleGraphDPoPHeader)
        }

        let trimmedNM = trimmedEntityTag(ifNoneMatch)
        if let trimmedNM, !trimmedNM.isEmpty {
            request.setValue(trimmedNM, forHTTPHeaderField: "If-None-Match")
        }

        let (firstData, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SocialWireError.badResponse("Missing gateway response.")
        }

        await captureNonces(from: http, session: session)

        let initial = GatewayHTTPResult(
            statusCode: http.statusCode,
            etagHeader: http.value(forHTTPHeaderField: "ETag"),
            requestIdHeader: http.value(forHTTPHeaderField: "X-Request-ID"),
            body: firstData
        )

        if shouldRetryNonceChallenge(http) {
            var retry = URLRequest(url: url)
            retry.httpMethod = method
            retry.setValue("application/json", forHTTPHeaderField: "Accept")
            if let body {
                retry.httpBody = body
            }
            if let contentType {
                retry.setValue(contentType, forHTTPHeaderField: "Content-Type")
            }
            try await authorize(&retry, session: session)
            if let wireModerationProofs {
                retry.setValue(wireModerationProofs, forHTTPHeaderField: Self.wireModerationDPoPHeader)
            }
            if let circleGraphProofs {
                retry.setValue(circleGraphProofs, forHTTPHeaderField: Self.circleGraphDPoPHeader)
            }
            if let trimmedNM, !trimmedNM.isEmpty {
                retry.setValue(trimmedNM, forHTTPHeaderField: "If-None-Match")
            }

            let (retryData, retryResponse) = try await urlSession.data(for: retry)
            guard let retryHttp = retryResponse as? HTTPURLResponse else {
                throw SocialWireError.badResponse("Missing gateway response.")
            }
            await captureNonces(from: retryHttp, session: session)
            return GatewayHTTPResult(
                statusCode: retryHttp.statusCode,
                etagHeader: retryHttp.value(forHTTPHeaderField: "ETag"),
                requestIdHeader: retryHttp.value(forHTTPHeaderField: "X-Request-ID"),
                body: retryData
            )
        }

        return initial
    }

    private func wireViewerModerationProofPool(session: AuthSession) async throws -> String {
        try await pdsProofPool(nsids: Self.wireViewerModerationNSIDs, session: session)
    }

    private func circleViewerGraphProofPool(session: AuthSession) async throws -> String {
        try await pdsProofPool(nsids: Self.circleViewerGraphNSIDs, session: session)
    }

    private func pdsProofPool(nsids: [String], session: AuthSession) async throws -> String {
        var proofs: [String] = []
        for nsid in nsids {
            await auth.dpop.advancePdsDpopNonce(session: session, urlSession: urlSession)
            let url = session.pdsURL.appending(path: "xrpc/\(nsid)")
            proofs.append(
                try await auth.dpop.proof(
                    method: "GET",
                    url: url,
                    accessToken: session.accessToken
                )
            )
        }
        return proofs.joined(separator: ",")
    }

    private func authorize(_ request: inout URLRequest, session: AuthSession) async throws {
        guard let url = request.url else { throw SocialWireError.invalidURL }
        let method = request.httpMethod ?? "GET"

        request.setValue("DPoP \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(
            try await auth.dpop.proof(method: method, url: url, accessToken: session.accessToken),
            forHTTPHeaderField: "DPoP"
        )
        let getSessionURL = ATProtoSessionDPoP.getSessionURL(for: session)
        request.setValue(
            try await auth.dpop.proof(
                method: "GET",
                url: getSessionURL,
                accessToken: session.accessToken
            ),
            forHTTPHeaderField: ATProtoSessionDPoP.headerName
        )
    }

    private func captureNonces(from response: HTTPURLResponse, session: AuthSession) async {
        await auth.dpop.updateNonce(from: response)
        await auth.dpop.updateSessionNonce(from: response, session: session)
    }

    private func shouldRetryNonceChallenge(_ response: HTTPURLResponse) -> Bool {
        guard [400, 401].contains(response.statusCode) else { return false }
        return response.value(forHTTPHeaderField: "DPoP-Nonce") != nil
            || ATProtoSessionDPoP.isNonceChallenge(response)
    }

    private func trimmedEntityTag(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        if trimmed.first == "\"" {
            let drop = trimmed.dropFirst().dropLast(trimmed.hasSuffix("\"") ? 1 : 0)
            return drop.isEmpty ? nil : String(drop)
        }
        return trimmed
    }
}
