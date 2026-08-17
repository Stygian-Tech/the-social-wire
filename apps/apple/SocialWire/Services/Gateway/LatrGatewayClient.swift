import Foundation
import LatrKit

/// Bookmark XRPC client routed through the Social Wire Gateway. Application credentials remain
/// server-side; the native client supplies gateway-, L@tr-, and PDS-bound DPoP proofs.
@MainActor
final class LatrGatewayClient {
    private static let contractVersion = "link.latr.bookmarks.v1"
    private static let sessionAttestationPreflightPath = "xrpc/app.thesocialwire.appview.listEntries"
    private static let maximumAttestationCeremonies = 2

    private struct PreparedGatewaySession {
        let session: AuthSession
        let attestationReceipt: String?
    }

    private enum AttestationCeremonyError: Error {
        case refreshRequired
    }

    enum AttestationCeremonyResult<Value> {
        case success(Value)
        case refreshRequired
    }

    enum AttestationCeremonyLimitError: Error {
        case exhausted
    }

    private let auth: ATProtoOAuthService
    private let transportBaseURL: URL
    private let proofBaseURL: URL
    private let urlSession: URLSession

    init(
        auth: ATProtoOAuthService,
        transportBaseURL: URL = LatrGatewayEnvironment.transportBaseURL,
        proofBaseURL: URL = LatrGatewayEnvironment.proofBaseURL,
        urlSession: URLSession = .shared
    ) {
        self.auth = auth
        self.transportBaseURL = transportBaseURL
        self.proofBaseURL = proofBaseURL
        self.urlSession = urlSession
    }

    func listBookmarks() async throws -> [MergedLatrSave] {
        var cursor: String?
        var rows: [MergedLatrSave] = []
        repeat {
            var query = [URLQueryItem(name: "limit", value: "50")]
            if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
            let data = try await request(
                method: "GET",
                xrpc: .listBookmarks,
                query: query
            )
            let page = try JSONDecoder().decode(LatrListBookmarksOutput.self, from: data)
            rows.append(contentsOf: page.bookmarks.map(Self.row))
            cursor = page.cursor?.trimmingCharacters(in: .whitespacesAndNewlines)
            if cursor?.isEmpty == true { cursor = nil }
        } while cursor != nil
        return rows.sorted { $0.savedAt > $1.savedAt }
    }

    func bookmark(subject: String) async throws -> MergedLatrSave? {
        let data = try await request(
            method: "GET",
            xrpc: .getBookmark,
            query: [URLQueryItem(name: "subject", value: subject)]
        )
        return try JSONDecoder().decode(LatrGetBookmarkOutput.self, from: data).bookmark.map(Self.row)
    }

    func save(subject: String) async throws {
        _ = try await request(
            method: "POST",
            xrpc: .saveBookmark,
            body: try JSONEncoder().encode(LatrSaveBookmarkInput(subject: subject))
        )
    }

    func archive(bookmarkURI: String) async throws {
        try await setState(bookmarkURI: bookmarkURI, state: .archived)
    }

    func unarchive(bookmarkURI: String) async throws {
        try await setState(bookmarkURI: bookmarkURI, state: .unread)
    }

    func delete(bookmarkURI: String) async throws {
        _ = try await request(
            method: "POST",
            xrpc: .deleteBookmark,
            body: try JSONEncoder().encode(LatrDeleteBookmarkInput(bookmarkUri: bookmarkURI))
        )
    }

    /// Runs once per viewer and contract version. Completion is persisted only after the final
    /// cursor succeeds; conflicts deliberately remain retryable on a later load.
    func migrateLegacyIfNeeded(viewerDID: String) async throws -> Int {
        let key = "the-social-wire.latr-migration.\(Self.contractVersion).\(viewerDID)"
        guard !UserDefaults.standard.bool(forKey: key) else { return 0 }
        var cursor: String?
        var conflicts = 0
        repeat {
            let input = LatrMigrateBookmarksInput(limit: 25, cursor: cursor)
            let data = try await migrateLegacyPage(input)
            let page = try JSONDecoder().decode(LatrBookmarkMigrationResult.self, from: data)
            guard page.ok else {
                throw SocialWireError.badResponse("L@tr legacy bookmark migration did not complete.")
            }
            conflicts += page.skippedConflict
            cursor = page.cursor?.trimmingCharacters(in: .whitespacesAndNewlines)
            if cursor?.isEmpty == true { cursor = nil }
        } while cursor != nil
        if conflicts == 0 { UserDefaults.standard.set(true, forKey: key) }
        return conflicts
    }

    private func migrateLegacyPage(_ input: LatrMigrateBookmarksInput) async throws -> Data {
        do {
            return try await Self.performAttestationCeremonies { _ in
                let prepared = try await self.preparedGatewaySession()
                var body = try JSONSerialization.jsonObject(
                    with: JSONEncoder().encode(input)
                ) as? [String: Any] ?? [:]
                body["upstreamDpopProof"] = try await self.upstreamProofPool(
                    for: .migrateBookmarks,
                    session: prepared.session
                )
                do {
                    return .success(try await self.request(
                        method: "POST",
                        xrpc: .migrateBookmarks,
                        body: try JSONSerialization.data(withJSONObject: body),
                        bodyCarriesUpstreamProof: true,
                        preparedSession: prepared
                    ))
                } catch AttestationCeremonyError.refreshRequired {
                    return .refreshRequired
                }
            }
        } catch AttestationCeremonyLimitError.exhausted {
            throw SocialWireError.badResponse(
                "Gateway session attestation expired while preparing the migration."
            )
        }
    }

    static func performAttestationCeremonies<Value>(
        attempt: (Int) async throws -> AttestationCeremonyResult<Value>
    ) async throws -> Value {
        for ceremony in 0 ..< maximumAttestationCeremonies {
            switch try await attempt(ceremony) {
            case .success(let value):
                return value
            case .refreshRequired:
                if ceremony + 1 == maximumAttestationCeremonies {
                    throw AttestationCeremonyLimitError.exhausted
                }
            }
        }
        throw AttestationCeremonyLimitError.exhausted
    }

    private func setState(bookmarkURI: String, state: SavedItemState) async throws {
        _ = try await request(
            method: "POST",
            xrpc: .setBookmarkState,
            body: try JSONEncoder().encode(
                LatrSetBookmarkStateInput(bookmarkUri: bookmarkURI, state: state)
            )
        )
    }

    private func request(
        method: String,
        xrpc: LatrXRPCMethod,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        bodyCarriesUpstreamProof: Bool = false,
        preparedSession: PreparedGatewaySession? = nil
    ) async throws -> Data {
        var components = URLComponents(
            url: transportBaseURL.appending(path: "xrpc/\(xrpc.nsid)"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = query.isEmpty ? nil : query
        guard let url = components?.url else { throw SocialWireError.invalidURL }

        let ceremonyLimit = preparedSession == nil ? Self.maximumAttestationCeremonies : 1
        for ceremony in 0 ..< ceremonyLimit {
            let prepared: PreparedGatewaySession
            if let preparedSession {
                prepared = preparedSession
            } else {
                prepared = try await preparedGatewaySession()
            }
            do {
                return try await requestOnce(
                    method: method,
                    xrpc: xrpc,
                    url: url,
                    body: body,
                    bodyCarriesUpstreamProof: bodyCarriesUpstreamProof,
                    prepared: prepared
                )
            } catch AttestationCeremonyError.refreshRequired {
                if ceremony + 1 == ceremonyLimit {
                    if preparedSession != nil { throw AttestationCeremonyError.refreshRequired }
                    throw SocialWireError.badResponse(
                        "Gateway session attestation expired while preparing the request."
                    )
                }
            }
        }
        throw SocialWireError.badResponse("Gateway session attestation did not complete.")
    }

    private func requestOnce(
        method: String,
        xrpc: LatrXRPCMethod,
        url: URL,
        body: Data?,
        bodyCarriesUpstreamProof: Bool,
        prepared: PreparedGatewaySession
    ) async throws -> Data {
        let session = prepared.session
        let preparedUpstreamProof = bodyCarriesUpstreamProof
            ? nil
            : try await upstreamProofPool(for: xrpc, session: session)

        func signedRequest() async throws -> URLRequest {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let body {
                request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            request.setValue("DPoP \(session.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(
                try await auth.dpop.proof(method: method, url: url, accessToken: session.accessToken),
                forHTTPHeaderField: "DPoP"
            )
            if LatrGatewayEnvironment.usesDirectExternalGateway {
                if let clientID = LatrGatewayEnvironment.developerClientId,
                   let apiKey = LatrGatewayEnvironment.developerApiKey
                {
                    request.setValue(clientID, forHTTPHeaderField: "X-Latr-Client-Id")
                    request.setValue(apiKey, forHTTPHeaderField: "X-Latr-API-Key")
                } else if let credential = LatrGatewayEnvironment.officialClientCredential {
                    request.setValue(credential, forHTTPHeaderField: "X-Latr-Official-Client")
                }
            } else {
                let latrURL = proofBaseURL.appending(path: "xrpc/\(xrpc.nsid)")
                request.setValue(
                    try await auth.dpop.proof(method: method, url: latrURL, accessToken: session.accessToken),
                    forHTTPHeaderField: LatrGatewayEnvironment.latrGatewayDPoPHeaderName
                )
            }
            Self.applyPreparedUpstreamProof(preparedUpstreamProof, to: &request)
            if !LatrGatewayEnvironment.usesDirectExternalGateway {
                Self.applyPreparedAttestation(
                    receipt: prepared.attestationReceipt,
                    bodyCarriesUpstreamProof: bodyCarriesUpstreamProof,
                    to: &request
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
            return request
        }

        let initial = try await signedRequest()
        let (data, response) = try await urlSession.data(for: initial)
        guard let http = response as? HTTPURLResponse else {
            throw SocialWireError.badResponse("Missing L@tr gateway response.")
        }
        await captureNonce(from: http, xrpc: xrpc, session: session)
        if ATProtoSessionDPoP.isAttestationRequired(http) {
            throw AttestationCeremonyError.refreshRequired
        }
        if shouldRetryNonceChallenge(http) {
            let retry = try await signedRequest()
            let (retryData, retryResponse) = try await urlSession.data(for: retry)
            guard let retryHTTP = retryResponse as? HTTPURLResponse else {
                throw SocialWireError.badResponse("Missing L@tr gateway response.")
            }
            await captureNonce(from: retryHTTP, xrpc: xrpc, session: session)
            if ATProtoSessionDPoP.isAttestationRequired(retryHTTP) {
                throw AttestationCeremonyError.refreshRequired
            }
            try validate(retryHTTP, data: retryData)
            return retryData
        }
        try validate(http, data: data)
        return data
    }

    private func captureNonce(
        from response: HTTPURLResponse,
        xrpc: LatrXRPCMethod,
        session: AuthSession
    ) async {
        await auth.dpop.updateNonce(from: response)
        if !LatrGatewayEnvironment.usesDirectExternalGateway {
            await auth.dpop.updateSessionNonce(from: response, session: session)
        }
        guard !LatrGatewayEnvironment.usesDirectExternalGateway,
              let nonce = response.value(forHTTPHeaderField: "DPoP-Nonce")
        else { return }
        await auth.dpop.updateNonce(
            nonce,
            for: proofBaseURL.appending(path: "xrpc/\(xrpc.nsid)")
        )
    }

    private func shouldRetryNonceChallenge(_ response: HTTPURLResponse) -> Bool {
        guard [400, 401].contains(response.statusCode) else { return false }
        return response.value(forHTTPHeaderField: "DPoP-Nonce") != nil
            || (!LatrGatewayEnvironment.usesDirectExternalGateway
                && ATProtoSessionDPoP.isNonceChallenge(response))
    }

    private func preparedGatewaySession() async throws -> PreparedGatewaySession {
        let session = try await auth.validSession()
        if !LatrGatewayEnvironment.usesDirectExternalGateway {
            return PreparedGatewaySession(
                session: session,
                attestationReceipt: try await warmSessionAttestation(session: session)
            )
        }
        return PreparedGatewaySession(session: session, attestationReceipt: nil)
    }

    private func warmSessionAttestation(session: AuthSession) async throws -> String? {
        var components = URLComponents(
            url: transportBaseURL.appending(path: Self.sessionAttestationPreflightPath),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "authorDid", value: session.did),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let url = components?.url else { throw SocialWireError.invalidURL }

        func signedRequest() async throws -> URLRequest {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("DPoP \(session.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(
                try await auth.dpop.proof(method: "GET", url: url, accessToken: session.accessToken),
                forHTTPHeaderField: "DPoP"
            )
            request.setValue(
                try await auth.dpop.proof(
                    method: "GET",
                    url: ATProtoSessionDPoP.getSessionURL(for: session),
                    accessToken: session.accessToken
                ),
                forHTTPHeaderField: ATProtoSessionDPoP.headerName
            )
            return request
        }

        let (_, response) = try await urlSession.data(for: signedRequest())
        guard var http = response as? HTTPURLResponse else {
            throw SocialWireError.badResponse("Missing session-attestation preflight response.")
        }
        await captureGatewaySessionNonces(from: http, session: session)

        if shouldRetryNonceChallenge(http) {
            let (_, retryResponse) = try await urlSession.data(for: signedRequest())
            guard let retryHTTP = retryResponse as? HTTPURLResponse else {
                throw SocialWireError.badResponse("Missing session-attestation preflight response.")
            }
            http = retryHTTP
            await captureGatewaySessionNonces(from: retryHTTP, session: session)
        }

        guard (200 ..< 300).contains(http.statusCode) else {
            throw SocialWireError.badResponse(
                "Session-attestation preflight failed (\(http.statusCode))."
            )
        }
        return ATProtoSessionDPoP.receipt(from: http)
    }

    private func captureGatewaySessionNonces(
        from response: HTTPURLResponse,
        session: AuthSession
    ) async {
        await auth.dpop.updateNonce(from: response)
        await auth.dpop.updateSessionNonce(from: response, session: session)
    }

    private func upstreamProofPool(
        for method: LatrXRPCMethod,
        session: AuthSession
    ) async throws -> String {
        let specs = Self.proofSpecs(for: method)
        var proofs: [String] = []
        for spec in specs {
            let url = session.pdsURL.appending(path: "xrpc/\(spec.nsid)")
            for _ in 0 ..< spec.count {
                await auth.dpop.advancePdsDpopNonce(session: session, urlSession: urlSession)
                proofs.append(
                    try await auth.dpop.proof(
                        method: spec.httpMethod,
                        url: url,
                        accessToken: session.accessToken
                    )
                )
            }
        }
        return proofs.joined(separator: ",")
    }

    nonisolated static func applyPreparedUpstreamProof(
        _ proof: String?,
        to request: inout URLRequest
    ) {
        guard let proof, !proof.isEmpty else { return }
        request.setValue(proof, forHTTPHeaderField: "X-ATProto-Upstream-DPoP")
    }

    nonisolated static func applyPreparedAttestation(
        receipt: String?,
        bodyCarriesUpstreamProof: Bool,
        to request: inout URLRequest
    ) {
        if let receipt = receipt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !receipt.isEmpty
        {
            request.setValue(
                receipt,
                forHTTPHeaderField: ATProtoSessionDPoP.receiptHeaderName
            )
        }
        if bodyCarriesUpstreamProof {
            request.setValue(
                "true",
                forHTTPHeaderField: ATProtoSessionDPoP.preparedUpstreamDPoPHeaderName
            )
        }
    }

    nonisolated static func proofSpecs(for method: LatrXRPCMethod) -> [(nsid: String, httpMethod: String, count: Int)] {
        switch method {
        case .listBookmarks:
            [("com.atproto.repo.listRecords", "GET", 9)]
        case .getBookmark:
            [("com.atproto.repo.listRecords", "GET", 8), ("com.atproto.repo.getRecord", "GET", 1)]
        case .saveBookmark:
            [("com.atproto.repo.listRecords", "GET", 8), ("com.atproto.repo.getRecord", "GET", 2), ("com.atproto.repo.applyWrites", "POST", 1)]
        case .setBookmarkState, .deleteBookmark:
            [("com.atproto.repo.getRecord", "GET", 2), ("com.atproto.repo.applyWrites", "POST", 1)]
        case .migrateBookmarks:
            [("com.atproto.repo.listRecords", "GET", 40), ("com.atproto.repo.getRecord", "GET", 25), ("com.atproto.repo.applyWrites", "POST", 25)]
        default:
            []
        }
    }

    private func validate(_ response: HTTPURLResponse, data: Data) throws {
        guard (200 ..< 300).contains(response.statusCode) else {
            let error = try? JSONDecoder().decode(LatrXRPCErrorBody.self, from: data)
            throw SocialWireError.badResponse(error?.message ?? error?.error ?? "L@tr gateway request failed (\(response.statusCode)).")
        }
    }

    private static func row(_ view: BookmarkView) -> MergedLatrSave {
        let subject = view.value.subject
        let state = view.metadataRecord?.value.state?.rawValue ?? "unread"
        let common = (
            savedAt: view.value.createdAt,
            itemRkey: view.uri,
            itemUri: view.uri,
            subjectUri: subject,
            state: state,
            lastOpenedAt: view.metadataRecord?.value.lastOpenedAt,
            title: view.preview?.title,
            excerpt: view.preview?.description,
            image: view.preview?.image,
            site: view.preview?.siteName,
            author: view.preview?.author
        )
        if let url = URL(string: subject), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            return .external(MergedLatrExternalSave(
                normalizedUrl: subject,
                url: subject,
                savedAt: common.savedAt,
                externalRkey: "",
                itemRkey: common.itemRkey,
                externalUri: subject,
                itemUri: common.itemUri,
                subjectUri: common.subjectUri,
                state: common.state,
                lastOpenedAt: common.lastOpenedAt,
                title: common.title,
                excerpt: common.excerpt,
                image: common.image,
                site: common.site,
                author: common.author,
                publishedAt: nil,
                language: nil,
                linkedWebUrl: nil,
                rowSubtitle: nil
            ))
        }
        return .native(MergedLatrNativeSave(
            savedAt: common.savedAt,
            itemRkey: common.itemRkey,
            itemUri: common.itemUri,
            subjectUri: common.subjectUri,
            state: common.state,
            lastOpenedAt: common.lastOpenedAt,
            title: common.title,
            excerpt: common.excerpt,
            image: common.image,
            site: common.site,
            author: common.author,
            publishedAt: nil,
            language: nil,
            linkedWebUrl: nil,
            rowSubtitle: nil
        ))
    }
}
