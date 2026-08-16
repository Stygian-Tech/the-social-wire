import Foundation

/// Authenticated calls to **`SocialWireAPIEnvironment.baseURL`** (DPoP + access JWT), mirroring PDS **`XRPCClient`** semantics.
@MainActor
final class SocialWireGatewayClient {
    private struct EmptyXRPCInput: Encodable {}

    private let auth: ATProtoOAuthService
    private let baseURL: URL
    private let urlSession: URLSession

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
        await auth.dpop.updateNonce(from: http)

        // Cold-origin DPoP-nonce challenge: the server replies 401/400 with a fresh DPoP-Nonce when
        // the client hasn't seeded one yet. Re-authorize with that nonce and retry once (mirrors
        // authorizedRequest); otherwise a first-launch challenge would fail the whole bootstrap.
        if [401, 400].contains(http.statusCode), http.value(forHTTPHeaderField: "DPoP-Nonce") != nil {
            (bytes, response) = try await urlSession.bytes(for: authorizedStreamRequest())
            guard let retryHttp = response as? HTTPURLResponse else {
                throw SocialWireError.badResponse("Missing gateway response.")
            }
            http = retryHttp
            await auth.dpop.updateNonce(from: http)
        }

        if http.statusCode == 401 {
            auth.invalidateSessionAfterUnauthorizedResponse()
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
        query: [String: String]
    ) async throws -> GatewayHTTPResult {
        let first = try await authorizedGET(path: path, query: query, ifNoneMatch: nil)
        guard !(200 ..< 300).contains(first.statusCode),
              let envelope = try? JSONDecoder().decode(AppViewErrorEnvelopeDTO.self, from: first.body),
              envelope.retryable
        else {
            return first
        }
        return try await authorizedGET(path: path, query: query, ifNoneMatch: nil)
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
        ifNoneMatch: String? = nil
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

        let trimmedNM = trimmedEntityTag(ifNoneMatch)
        if let trimmedNM, !trimmedNM.isEmpty {
            request.setValue(trimmedNM, forHTTPHeaderField: "If-None-Match")
        }

        let (firstData, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SocialWireError.badResponse("Missing gateway response.")
        }

        await auth.dpop.updateNonce(from: http)

        let initial = GatewayHTTPResult(
            statusCode: http.statusCode,
            etagHeader: http.value(forHTTPHeaderField: "ETag"),
            requestIdHeader: http.value(forHTTPHeaderField: "X-Request-ID"),
            body: firstData
        )

        if [401, 400].contains(http.statusCode), http.value(forHTTPHeaderField: "DPoP-Nonce") != nil {
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
            if let trimmedNM, !trimmedNM.isEmpty {
                retry.setValue(trimmedNM, forHTTPHeaderField: "If-None-Match")
            }

            let (retryData, retryResponse) = try await urlSession.data(for: retry)
            guard let retryHttp = retryResponse as? HTTPURLResponse else {
                throw SocialWireError.badResponse("Missing gateway response.")
            }
            await auth.dpop.updateNonce(from: retryHttp)
            if retryHttp.statusCode == 401 {
                auth.invalidateSessionAfterUnauthorizedResponse()
            }
            return GatewayHTTPResult(
                statusCode: retryHttp.statusCode,
                etagHeader: retryHttp.value(forHTTPHeaderField: "ETag"),
                requestIdHeader: retryHttp.value(forHTTPHeaderField: "X-Request-ID"),
                body: retryData
            )
        }

        if http.statusCode == 401 {
            auth.invalidateSessionAfterUnauthorizedResponse()
        }
        return initial
    }

    private func authorize(_ request: inout URLRequest, session: AuthSession) async throws {
        guard let url = request.url else { throw SocialWireError.invalidURL }
        let method = request.httpMethod ?? "GET"

        request.setValue("DPoP \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(
            try await auth.dpop.proof(method: method, url: url, accessToken: session.accessToken),
            forHTTPHeaderField: "DPoP"
        )
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
