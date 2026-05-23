import Foundation

/// Authenticated calls to **`SocialWireAPIEnvironment.baseURL`** (DPoP + access JWT), mirroring PDS **`XRPCClient`** semantics.
@MainActor
final class SocialWireGatewayClient {
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
        try await authorizedGET(path: "/v1/sync/preferences", query: [:], ifNoneMatch: ifNoneMatch)
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
            path: "/v1/publications/sidebar",
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
        let result = try await authorizedRequest(
            method: "POST",
            path: "/v1/publications/refresh",
            query: [:],
            body: nil,
            contentType: nil
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
            path: "/v1/publications/resolve",
            query: [:],
            body: payload,
            contentType: "application/json"
        )
        guard (200 ..< 300).contains(result.statusCode) else {
            throw SocialWireError.badResponse("Publication resolve failed (\(result.statusCode)).")
        }
        return try JSONDecoder().decode(ResolveAddPublicationResponseDTO.self, from: result.body)
    }

    func createFolder(_ input: GatewayFolderWriteBody) async throws -> GatewayRecordWriteResponseDTO {
        let payload = try JSONEncoder().encode(input)
        let result = try await authorizedRequest(
            method: "POST",
            path: "/v1/publications/folders",
            query: [:],
            body: payload,
            contentType: "application/json"
        )
        guard (200 ..< 300).contains(result.statusCode) else {
            throw SocialWireError.badResponse("Create folder failed (\(result.statusCode)).")
        }
        return try JSONDecoder().decode(GatewayRecordWriteResponseDTO.self, from: result.body)
    }

    func updateFolder(rkey: String, input: GatewayFolderWriteBody) async throws {
        let payload = try JSONEncoder().encode(input)
        let result = try await authorizedRequest(
            method: "PUT",
            path: "/v1/publications/folders/\(rkey)",
            query: [:],
            body: payload,
            contentType: "application/json"
        )
        guard (200 ..< 300).contains(result.statusCode) else {
            throw SocialWireError.badResponse("Update folder failed (\(result.statusCode)).")
        }
    }

    func deleteFolder(rkey: String) async throws {
        let result = try await authorizedRequest(
            method: "DELETE",
            path: "/v1/publications/folders/\(rkey)",
            query: [:],
            body: nil,
            contentType: nil
        )
        guard (200 ..< 300).contains(result.statusCode) else {
            throw SocialWireError.badResponse("Delete folder failed (\(result.statusCode)).")
        }
    }

    func upsertPublicationPrefs(_ input: GatewayPublicationPrefsWriteBody) async throws -> GatewayRecordWriteResponseDTO {
        let payload = try JSONEncoder().encode(input)
        let result = try await authorizedRequest(
            method: "PUT",
            path: "/v1/publications/prefs",
            query: [:],
            body: payload,
            contentType: "application/json"
        )
        guard (200 ..< 300).contains(result.statusCode) else {
            throw SocialWireError.badResponse("Publication prefs upsert failed (\(result.statusCode)).")
        }
        return try JSONDecoder().decode(GatewayRecordWriteResponseDTO.self, from: result.body)
    }

    func createPublicationSubscription(_ input: GatewayPublicationSubscriptionWriteBody) async throws -> GatewayRecordWriteResponseDTO {
        let payload = try JSONEncoder().encode(input)
        let result = try await authorizedRequest(
            method: "POST",
            path: "/v1/publications/subscriptions",
            query: [:],
            body: payload,
            contentType: "application/json"
        )
        guard (200 ..< 300).contains(result.statusCode) else {
            throw SocialWireError.badResponse("Create subscription failed (\(result.statusCode)).")
        }
        return try JSONDecoder().decode(GatewayRecordWriteResponseDTO.self, from: result.body)
    }

    func deletePublicationSubscription(rkey: String) async throws {
        let result = try await authorizedRequest(
            method: "DELETE",
            path: "/v1/publications/subscriptions/\(rkey)",
            query: [:],
            body: nil,
            contentType: nil
        )
        guard (200 ..< 300).contains(result.statusCode) else {
            throw SocialWireError.badResponse("Delete subscription failed (\(result.statusCode)).")
        }
    }

    func createRssSubscription(_ input: GatewayRssSubscriptionWriteBody) async throws -> GatewayRecordWriteResponseDTO {
        let payload = try JSONEncoder().encode(input)
        let result = try await authorizedRequest(
            method: "POST",
            path: "/v1/publications/rss-subscriptions",
            query: [:],
            body: payload,
            contentType: "application/json"
        )
        guard (200 ..< 300).contains(result.statusCode) else {
            throw SocialWireError.badResponse("Create RSS subscription failed (\(result.statusCode)).")
        }
        return try JSONDecoder().decode(GatewayRecordWriteResponseDTO.self, from: result.body)
    }

    func deleteRssSubscription(rkey: String) async throws {
        let result = try await authorizedRequest(
            method: "DELETE",
            path: "/v1/publications/rss-subscriptions/\(rkey)",
            query: [:],
            body: nil,
            contentType: nil
        )
        guard (200 ..< 300).contains(result.statusCode) else {
            throw SocialWireError.badResponse("Delete RSS subscription failed (\(result.statusCode)).")
        }
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

        let result = try await authorizedGET(path: "/v1/appview/entries", query: query, ifNoneMatch: nil)
        if result.statusCode == 404 {
            throw SocialWireError.appViewUnavailable
        }
        guard (200 ..< 300).contains(result.statusCode) else {
            throw SocialWireError.badResponse("AppView entries failed (\(result.statusCode)).")
        }
        return try JSONDecoder().decode(AppViewEntryListResponse.self, from: result.body)
    }

    func fetchAppViewEntryDetail(entryId: String) async throws -> EntryDetail? {
        let result = try await authorizedGET(
            path: "/v1/appview/entry",
            query: ["entryId": entryId],
            ifNoneMatch: nil
        )
        if result.statusCode == 404 {
            return nil
        }
        guard (200 ..< 300).contains(result.statusCode) else {
            throw SocialWireError.badResponse("AppView entry detail failed (\(result.statusCode)).")
        }
        let decoded = try JSONDecoder().decode(AppViewEntryDetailResponse.self, from: result.body)
        return decoded.entry
    }

    func fetchAppViewUnreadCounts(publicationIds: [String]) async throws -> [String: Int] {
        guard !publicationIds.isEmpty else { return [:] }
        let result = try await authorizedGET(
            path: "/v1/appview/unread-counts",
            query: ["publicationIds": publicationIds.joined(separator: ",")],
            ifNoneMatch: nil
        )
        if result.statusCode == 404 {
            return [:]
        }
        guard (200 ..< 300).contains(result.statusCode) else {
            throw SocialWireError.badResponse("AppView unread counts failed (\(result.statusCode)).")
        }
        let decoded = try JSONDecoder().decode(AppViewUnreadCountsResponse.self, from: result.body)
        return decoded.counts ?? [:]
    }

    func upsertReadMark(subjectUri: String, readAt: Date) async throws {
        let payload = try JSONEncoder().encode(
            AppViewReadMarkBody(subjectUri: subjectUri, readAt: DateFormatters.string(from: readAt))
        )
        let result = try await authorizedRequest(
            method: "POST",
            path: "/v1/appview/read-marks",
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
            method: "DELETE",
            path: "/v1/appview/read-marks",
            query: [:],
            body: payload,
            contentType: "application/json"
        )
        guard (200 ..< 300).contains(result.statusCode) else {
            throw SocialWireError.badResponse("AppView read-mark delete failed (\(result.statusCode)).")
        }
    }

    func markAllRead(scope: GatewayMarkAllReadScopeDTO) async throws -> Int {
        let payload = try JSONEncoder().encode(GatewayMarkAllReadBody(scope: scope))
        let result = try await authorizedRequest(
            method: "POST",
            path: "/v1/appview/mark-all-read",
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
        let decoded = try JSONDecoder().decode(GatewayMarkAllReadResponseDTO.self, from: result.body)
        return decoded.marked
    }

    func enrollAuthors(dids: [String], feedUrls: [String] = []) async throws -> Int {
        let payload = try JSONEncoder().encode(AppViewEnrollBody(authorDids: dids, feedUrls: feedUrls))
        let result = try await authorizedRequest(
            method: "POST",
            path: "/v1/appview/enroll",
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
        let result = try await authorizedRequest(
            method: "DELETE",
            path: "/v1/appview/privacy/purge",
            query: [:],
            body: nil,
            contentType: nil
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
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
        try await authorize(&request, session: session)

        let (bytes, response) = try await urlSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SocialWireError.badResponse("Missing gateway response.")
        }
        await auth.dpop.updateNonce(from: http)
        guard (200 ..< 300).contains(http.statusCode) else {
            throw SocialWireError.badResponse("Bootstrap stream failed (\(http.statusCode)).")
        }

        var buffer = Data()
        for try await byte in bytes {
            buffer.append(byte)
            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[..<newlineIndex]
                buffer.removeSubrange(..<(newlineIndex + 1))
                let line = String(decoding: lineData, as: UTF8.self)
                try Self.consumeBootstrapLine(line, onEvent: onEvent)
            }
        }
        if !buffer.isEmpty {
            let line = String(decoding: buffer, as: UTF8.self)
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
        ifNoneMatch: String?
    ) async throws -> GatewayHTTPResult {
        try await authorizedRequest(
            method: "GET",
            path: path,
            query: query,
            body: nil,
            contentType: nil,
            ifNoneMatch: ifNoneMatch
        )
    }

    private func authorizedRequest(
        method: String,
        path: String,
        query: [String: String],
        body: Data?,
        contentType: String?,
        ifNoneMatch: String? = nil
    ) async throws -> GatewayHTTPResult {
        guard var comps = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw SocialWireError.invalidURL
        }
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
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

        try await authorize(
          &request,
          session: session,
          gatewayPath: path,
          gatewayMethod: method
        )

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
            try await authorize(
              &retry,
              session: session,
              gatewayPath: path,
              gatewayMethod: method
            )
            if let trimmedNM, !trimmedNM.isEmpty {
                retry.setValue(trimmedNM, forHTTPHeaderField: "If-None-Match")
            }

            let (retryData, retryResponse) = try await urlSession.data(for: retry)
            guard let retryHttp = retryResponse as? HTTPURLResponse else {
                throw SocialWireError.badResponse("Missing gateway response.")
            }
            await auth.dpop.updateNonce(from: retryHttp)
            return GatewayHTTPResult(
                statusCode: retryHttp.statusCode,
                etagHeader: retryHttp.value(forHTTPHeaderField: "ETag"),
                body: retryData
            )
        }

        return initial
    }

    private func authorize(
      _ request: inout URLRequest,
      session: AuthSession,
      gatewayPath: String,
      gatewayMethod: String
    ) async throws {
        guard let url = request.url else { throw SocialWireError.invalidURL }
        let method = request.httpMethod ?? gatewayMethod

        request.setValue("DPoP \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(
            try await auth.dpop.proof(method: method, url: url, accessToken: session.accessToken),
            forHTTPHeaderField: "DPoP"
        )

        if let xrpcMethod = Self.pdsXrpcMethod(gatewayMethod: gatewayMethod, path: gatewayPath) {
            let pdsXrpcURL = session.pdsURL
                .appending(path: "xrpc")
                .appending(path: xrpcMethod)
            let upstreamProof = try await auth.dpop.proof(
                method: method,
                url: pdsXrpcURL,
                accessToken: session.accessToken
            )
            request.setValue(upstreamProof, forHTTPHeaderField: "X-ATProto-Upstream-DPoP")
        }
    }

    /// Maps gateway publication write routes to the PDS XRPC method they write through.
    private static func pdsXrpcMethod(gatewayMethod: String, path: String) -> String? {
        let method = gatewayMethod.uppercased()
        switch method {
        case "POST":
            if path.hasSuffix("/subscriptions")
                || path.hasSuffix("/rss-subscriptions")
                || path.hasSuffix("/folders")
            {
                return "com.atproto.repo.createRecord"
            }
            if path.hasSuffix("/read-marks") || path.hasSuffix("/mark-all-read") {
                return "com.atproto.repo.putRecord"
            }
        case "PUT":
            if path.contains("/folders/") || path.hasSuffix("/prefs") {
                return "com.atproto.repo.putRecord"
            }
        case "DELETE":
            if path.contains("/subscriptions/")
                || path.contains("/rss-subscriptions/")
                || path.contains("/folders/")
                || path.hasSuffix("/read-marks")
            {
                return "com.atproto.repo.deleteRecord"
            }
        default:
            break
        }
        return nil
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
