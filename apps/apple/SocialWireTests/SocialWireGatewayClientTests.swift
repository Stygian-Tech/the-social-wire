import Foundation
import Testing
@testable import SocialWire

@Suite("SocialWireGatewayClient")
@MainActor
struct SocialWireGatewayClientTests {
    private static let financePage = #"{"feedId":"finance","items":[],"generationId":"generation","generatedAt":"2026-10-12T12:00:00Z","expiresAt":"2026-10-13T12:00:00Z","language":"en","preferenceRevision":"p","source":"generation","degraded":false}"#
    private static let proofRequired = OAuthTestTransport.Reply(status: 428, body: #"{"error":"UpstreamProofRequired","message":"Required","requestId":"test","retryable":false}"#)
    private static let attestationRequired = OAuthTestTransport.Reply(status: 428, body: #"{"error":"AttestationRequired"}"#, headers: [ATProtoSessionDPoP.attestationRequiredHeaderName: "true"])

    private func fixture(_ replies: [OAuthTestTransport.Reply], delay: Duration = .zero) async throws -> (ATProtoOAuthService, SocialWireGatewayClient, OAuthTestTransport) {
        let store = OAuthTestSessionStore()
        let auth = ATProtoOAuthService(keychain: store)
        let session = AuthSession(did: "did:plc:test", pdsURL: URL(string: "https://pds.example.test")!,
            tokenEndpoint: URL(string: "https://issuer.example/token")!, accessToken: "access",
            refreshToken: "refresh", tokenType: "DPoP", scope: ATProtoOAuthService.scopes, expiresAt: .distantFuture)
        let record: [String: Any] = [
            "session": try JSONSerialization.jsonObject(with: JSONEncoder().encode(session)),
            "dpopPrivateKey": Data(repeating: 1, count: 32).base64EncodedString(),
            "clientID": ATProtoOAuthConfig.clientID,
        ]
        store.set(try JSONSerialization.data(withJSONObject: record).base64EncodedString(), for: "oauth.session.v2")
        await auth.restoreSession()
        let transport = OAuthTestTransport(replies, delay: delay)
        let gateway = SocialWireGatewayClient(auth: auth, baseURL: URL(string: "https://gateway.example.test")!, transport: { try await transport.send($0) })
        return (auth, gateway, transport)
    }

    private func preparedReplies(receipt: String) -> [OAuthTestTransport.Reply] {
        [.init(status: 200, body: "{}", headers: [ATProtoSessionDPoP.receiptHeaderName: receipt])]
        + (0..<5).map { .init(status: 200, body: "{}", headers: ["DPoP-Nonce": "\(receipt)-nonce-\($0)"]) }
    }

    @Test("Warm feed snapshots and pagination perform no PDS proof probes")
    func warmFeedSkipsPools() async throws {
        let (auth, gateway, transport) = try await fixture([
            .init(status: 200, body: Self.financePage), .init(status: 200, body: Self.financePage),
        ])
        defer { auth.signOut() }
        _ = try await gateway.fetchFinance(language: "en")
        _ = try await gateway.fetchFinance(language: "en", cursor: "next")
        let requests = await transport.recordedRequests()
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.url?.host == "gateway.example.test" && $0.value(forHTTPHeaderField: SocialWireGatewayClient.wireModerationDPoPHeader) == nil })
    }

    @Test("Cold feed attests before distinct nonce probes and preserves pools on Gateway nonce retry")
    func coldFeedPreparedCeremony() async throws {
        let (auth, gateway, transport) = try await fixture([Self.proofRequired]
            + preparedReplies(receipt: "receipt")
            + [.init(status: 401, body: "{}", headers: ["DPoP-Nonce": "gateway-nonce"]), .init(status: 200, body: Self.financePage)])
        defer { auth.signOut() }
        _ = try await gateway.fetchFinance(language: "en")
        let requests = await transport.recordedRequests()
        #expect(requests.count == 9)
        #expect(requests[1].url?.path.hasSuffix("listEntries") == true)
        #expect(requests[2..<7].allSatisfy { $0.url?.host == "pds.example.test" })
        let initial = requests[7], retry = requests[8]
        #expect(initial.value(forHTTPHeaderField: ATProtoSessionDPoP.receiptHeaderName) == "receipt")
        #expect(initial.value(forHTTPHeaderField: ATProtoSessionDPoP.preparedUpstreamDPoPHeaderName) == "true")
        let pool = try #require(initial.value(forHTTPHeaderField: SocialWireGatewayClient.wireModerationDPoPHeader))
        #expect(pool.split(separator: ",").count == 5)
        #expect(retry.value(forHTTPHeaderField: SocialWireGatewayClient.wireModerationDPoPHeader) == pool)
        #expect(initial.value(forHTTPHeaderField: "DPoP") != retry.value(forHTTPHeaderField: "DPoP"))
    }

    @Test("Expired prepared attestation renews once and repeated proof challenges terminate")
    func boundedColdFeedRetries() async throws {
        let (auth, gateway, transport) = try await fixture([Self.proofRequired]
            + preparedReplies(receipt: "first") + [Self.attestationRequired]
            + preparedReplies(receipt: "second") + [Self.attestationRequired])
        defer { auth.signOut() }
        await #expect(throws: (any Error).self) { _ = try await gateway.fetchFinance(language: "en") }
        let requests = await transport.recordedRequests()
        #expect(requests.count == 15)
        #expect(requests[7].value(forHTTPHeaderField: ATProtoSessionDPoP.receiptHeaderName) == "first")
        #expect(requests[14].value(forHTTPHeaderField: ATProtoSessionDPoP.receiptHeaderName) == "second")
        #expect(requests[7].value(forHTTPHeaderField: SocialWireGatewayClient.wireModerationDPoPHeader) != requests[14].value(forHTTPHeaderField: SocialWireGatewayClient.wireModerationDPoPHeader))
    }

    @Test("An explicit proof challenge is retried only once")
    func proofChallengeIsBounded() async throws {
        let (auth, gateway, transport) = try await fixture([Self.proofRequired] + preparedReplies(receipt: "receipt") + [Self.proofRequired])
        defer { auth.signOut() }
        await #expect(throws: (any Error).self) { _ = try await gateway.fetchFinance(language: "en") }
        #expect(await transport.recordedRequests().count == 8)
    }

    @Test("Concurrent cold feeds cannot interleave PDS proof preparation")
    func concurrentColdFeedsSerializeNonceSequences() async throws {
        let (auth, gateway, transport) = try await fixture([Self.proofRequired, Self.proofRequired]
            + preparedReplies(receipt: "first") + [.init(status: 200, body: Self.financePage)]
            + preparedReplies(receipt: "second") + [.init(status: 200, body: Self.financePage)], delay: .milliseconds(20))
        defer { auth.signOut() }
        let first = Task { try await gateway.fetchFinance(language: "en") }
        while await transport.recordedRequests().isEmpty { await Task.yield() }
        let second = Task { try await gateway.fetchFinance(language: "en") }
        _ = try await first.value
        _ = try await second.value
        let requests = await transport.recordedRequests()
        #expect(requests.count == 16)
        #expect(requests[2].url?.path.hasSuffix("listEntries") == true)
        #expect(requests[3..<8].allSatisfy { $0.url?.host == "pds.example.test" })
        #expect(requests[8].value(forHTTPHeaderField: ATProtoSessionDPoP.receiptHeaderName) == "first")
        #expect(requests[9].url?.path.hasSuffix("listEntries") == true)
        #expect(requests[10..<15].allSatisfy { $0.url?.host == "pds.example.test" })
        #expect(requests[15].value(forHTTPHeaderField: ATProtoSessionDPoP.receiptHeaderName) == "second")
    }

    @Test("Signature-verified preflight may omit a receipt but still marks prepared proofs")
    func signatureVerifiedPreparedRequest() async throws {
        let probes = (0..<5).map { OAuthTestTransport.Reply(status: 200, body: "{}", headers: ["DPoP-Nonce": "nonce-\($0)"]) }
        let (auth, gateway, transport) = try await fixture([Self.proofRequired, .init(status: 200, body: "{}")]
            + probes + [.init(status: 200, body: Self.financePage)])
        defer { auth.signOut() }
        _ = try await gateway.fetchFinance(language: "en")
        let request = try #require(await transport.recordedRequests().last)
        #expect(request.value(forHTTPHeaderField: ATProtoSessionDPoP.receiptHeaderName) == nil)
        #expect(request.value(forHTTPHeaderField: ATProtoSessionDPoP.preparedUpstreamDPoPHeaderName) == "true")
    }

    @Test("Detached media download uses prepared attestation without consuming a later pool nonce")
    func mediaRequestHasPreparedReceipt() async throws {
        let (auth, gateway, transport) = try await fixture([
            .init(status: 200, body: "{}", headers: [ATProtoSessionDPoP.receiptHeaderName: "download-receipt"]),
        ])
        defer { auth.signOut() }
        let request = try await gateway.podcastDownloadRequest(media: "/v1/podcasts/media?source=test", expectedViewer: "did:plc:test")
        #expect(request.value(forHTTPHeaderField: ATProtoSessionDPoP.receiptHeaderName) == "download-receipt")
        #expect(request.value(forHTTPHeaderField: ATProtoSessionDPoP.preparedUpstreamDPoPHeaderName) == "true")
        #expect(await transport.recordedRequests().count == 1)
    }

    @Test("Post-write preference reads bypass both gateway and conditional caches")
    func postWritePreferencesRequireFreshSnapshot() {
        let request = SocialWireGatewayClient.preferencesSyncRequest(
            ifNoneMatch: "\"previous-revision\"",
            forceRefresh: true
        )
        #expect(request.query["fresh"] == "true")
        #expect(request.ifNoneMatch == nil)
    }

    @Test("Ordinary preference reads retain conditional cache validation")
    func ordinaryPreferencesKeepConditionalCache() {
        let request = SocialWireGatewayClient.preferencesSyncRequest(
            ifNoneMatch: "\"current-revision\"",
            forceRefresh: false
        )
        #expect(request.query.isEmpty)
        #expect(request.ifNoneMatch == "\"current-revision\"")
    }

    @Test("Read-age snapshots stream before completion and replace prior counts")
    func readAgeSnapshotsStreamProgressively() async throws {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        continuation.yield(#"{"type":"options","referenceDay":"2026-09-07","options":[{"days":7,"before":"2026-08-31T05:00:00Z","count":2}]}"#)
        var snapshots: [[FeedReadAgeOption]] = []
        let response = try await FeedReadAgeStreamEvent.consume(stream) { options in
            snapshots.append(options)
            if snapshots.count == 1 {
                // No next event exists until the first snapshot is delivered to the menu.
                continuation.yield(#"{"type":"options","referenceDay":"2026-09-07","options":[{"days":7,"before":"2026-08-31T05:00:00Z","count":5}]}"#)
            } else {
                continuation.yield(#"{"type":"done"}"#)
                continuation.finish()
            }
        }
        #expect(snapshots.map { $0[0].count } == [2, 5])
        #expect(response.options[0].count == 5)
        #expect(response.options[0].title == "1 Week")
    }

    @Test("Read-age partial responses require a terminal done event")
    func readAgeTruncationFails() async {
        let stream = AsyncThrowingStream<String, Error> { continuation in
            continuation.yield(#"{"type":"options","referenceDay":"2026-09-07","options":[]}"#)
            continuation.finish()
        }
        await #expect(throws: (any Error).self) {
            try await FeedReadAgeStreamEvent.consume(stream) { _ in }
        }
    }

    @Test("Read-age server errors fail even after options arrive")
    func readAgeTerminalErrorFails() async {
        let stream = AsyncThrowingStream<String, Error> { continuation in
            continuation.yield(#"{"type":"options","referenceDay":"2026-09-07","options":[]}"#)
            continuation.yield(#"{"type":"error","message":"Read query failed"}"#)
            continuation.finish()
        }
        await #expect(throws: (any Error).self) {
            try await FeedReadAgeStreamEvent.consume(stream) { _ in }
        }
    }

    @Test("Read-age done without options fails")
    func readAgeMissingSnapshotFails() async {
        let stream = AsyncThrowingStream<String, Error> { continuation in
            continuation.yield(#"{"type":"done"}"#)
            continuation.finish()
        }
        await #expect(throws: (any Error).self) {
            try await FeedReadAgeStreamEvent.consume(stream) { _ in }
        }
    }

    @Test("AppViewEnrollResponse decodes indexed count")
    func appViewEnrollResponseDecodesIndexedCount() throws {
        let data = Data("""
        {"indexed": 42}
        """.utf8)
        let decoded = try JSONDecoder().decode(AppViewEnrollResponse.self, from: data)
        #expect(decoded.indexed == 42)
    }

    @Test("PublicationSidebarResponseDTO decodes appViewScope and unread counts")
    func publicationSidebarDecodesScopeAndUnread() throws {
        let data = Data("""
        {
          "viewerDid": "did:plc:viewer",
          "allPublicationRows": [{
            "publicationId": "at://did:plc:author/site.standard.publication/p1",
            "authorDid": "did:plc:author",
            "title": "Pub",
            "discoveredAt": "2026-01-01T00:00:00.000Z",
            "unreadCount": 3,
            "appViewScope": {
              "authorDid": "did:plc:author",
              "publicationAtUri": "at://did:plc:author/site.standard.publication/p1",
              "publicationScopeAtUris": ["at://did:plc:author/com.standard.publication/p1"],
              "publicationSiteUrls": ["https://example.com"]
            }
          }],
          "folderSections": [{
            "folderRkey": "abc",
            "folderUri": "at://did:plc:viewer/app.thesocialwire.folder/abc",
            "publications": []
          }],
          "myPublications": [],
          "subscribedUnfoldered": [],
          "followingTabPublications": [],
          "enrollAuthorDids": ["did:plc:author"],
          "refreshedAt": "2026-01-01T00:00:00.000Z",
          "unreadCountsByPublicationId": {
            "at://did:plc:author/site.standard.publication/p1": 3
          }
        }
        """.utf8)
        let decoded = try JSONDecoder().decode(PublicationSidebarResponseDTO.self, from: data)
        #expect(decoded.allPublicationRows.count == 1)
        #expect(decoded.allPublicationRows[0].unreadCount == 3)
        #expect(decoded.folderSections?.count == 1)
        let counts = PublicationProjectionMapping.unreadCountsMap(from: decoded)
        #expect(counts["at://did:plc:author/site.standard.publication/p1"] == 3)
    }

    @Test("unreadCountsMap prefers unreadCountsByPublicationId over embedded row count")
    func unreadCountsMapPrefersRecordMap() throws {
        let data = Data("""
        {
          "viewerDid": "did:plc:viewer",
          "allPublicationRows": [{
            "publicationId": "did:plc:alice",
            "authorDid": "did:plc:alice",
            "title": "Alice",
            "discoveredAt": "2026-01-01T00:00:00.000Z",
            "unreadCount": 4,
            "appViewScope": {
              "authorDid": "did:plc:alice",
              "publicationAtUri": null,
              "publicationScopeAtUris": [],
              "publicationSiteUrls": []
            }
          }],
          "myPublications": [],
          "subscribedUnfoldered": [],
          "followingTabPublications": [],
          "enrollAuthorDids": [],
          "refreshedAt": "2026-01-01T00:00:00.000Z",
          "unreadCountsByPublicationId": { "did:plc:alice": 1 }
        }
        """.utf8)
        let decoded = try JSONDecoder().decode(PublicationSidebarResponseDTO.self, from: data)
        let counts = PublicationProjectionMapping.unreadCountsMap(from: decoded)
        #expect(counts["did:plc:alice"] == 1)
    }

    @Test("unreadCountsMap does not resurrect stale embedded counts when record map is empty")
    func unreadCountsMapIgnoresStaleEmbeddedWhenRecordEmpty() throws {
        let data = Data("""
        {
          "viewerDid": "did:plc:viewer",
          "allPublicationRows": [{
            "publicationId": "did:plc:alice",
            "authorDid": "did:plc:alice",
            "title": "Alice",
            "discoveredAt": "2026-01-01T00:00:00.000Z",
            "unreadCount": 2,
            "appViewScope": {
              "authorDid": "did:plc:alice",
              "publicationAtUri": null,
              "publicationScopeAtUris": [],
              "publicationSiteUrls": []
            }
          }],
          "myPublications": [],
          "subscribedUnfoldered": [],
          "followingTabPublications": [],
          "enrollAuthorDids": [],
          "refreshedAt": "2026-01-01T00:00:00.000Z",
          "unreadCountsByPublicationId": {}
        }
        """.utf8)
        let decoded = try JSONDecoder().decode(PublicationSidebarResponseDTO.self, from: data)
        let counts = PublicationProjectionMapping.unreadCountsMap(from: decoded)
        #expect(counts["did:plc:alice"] == nil)
    }

    @Test("AppViewEntryListResponse decodes entries")
    func appViewEntryListResponseDecodesEntries() throws {
        let data = Data("""
        {"entries":[{"entryId":"at://did/site.standard.document/a","title":"A","publishedAt":"2026-01-01T00:00:00.000Z","originalUrl":"https://example.com/a","isRead":true}],"cursor":null}
        """.utf8)
        let decoded = try JSONDecoder().decode(AppViewEntryListResponse.self, from: data)
        #expect(decoded.entries.count == 1)
        #expect(decoded.entries[0].title == "A")
        #expect(decoded.entries[0].originalUrl == "https://example.com/a")
        #expect(decoded.entries[0].isRead)
    }

    @Test("AppViewEntryDetailDTO decodes flat AppView entry payload")
    func appViewEntryDetailDTODecodesFlatPayload() throws {
        let data = Data("""
        {"entryId":"at://did/site.standard.document/a","title":"A","publishedAt":"2026-01-01T00:00:00.000Z","contentHtml":"<p>Hi</p>","originalUrl":"https://example.com/a","isRead":false}
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let dto = try decoder.decode(AppViewEntryDetailDTO.self, from: data)
        let entry = dto.toEntryDetail()
        #expect(entry.title == "A")
        #expect(entry.contentHtml == "<p>Hi</p>")
        #expect(entry.embedUrl == "https://example.com/a")
    }

    @Test("AppViewUnreadCountsResponse decodes count metadata")
    func appViewUnreadCountsResponseDecodesCounts() throws {
        let data = Data("""
        {"counts":{"at://did/site.standard.publication/p1":2},"generation":42,"accuracy":"exact","countedAt":"2026-01-01T00:00:00.000Z"}
        """.utf8)
        let decoded = try JSONDecoder().decode(AppViewUnreadCountsResponse.self, from: data)
        #expect(decoded.counts?["at://did/site.standard.publication/p1"] == 2)
        #expect(decoded.generation == 42)
        #expect(decoded.accuracy == "exact")
        #expect(decoded.countedAt == "2026-01-01T00:00:00.000Z")
    }

    @Test("GatewayMarkAllReadResponseDTO decodes confirmed boundaries")
    func gatewayMarkAllReadResponseDecodesMarked() throws {
        let data = Data("""
        {
          "marked": 7,
          "confirmedAt": "2026-07-28T20:00:00.000Z",
          "boundaries": [{
            "publicationId": "at://did/site.standard.publication/main",
            "createdAt": "2026-07-28T19:59:00.000Z",
            "entryId": "at://did/site.standard.document/latest"
          }],
          "unreadCounts": {"at://did/site.standard.publication/main": 0}
        }
        """.utf8)
        let decoded = try JSONDecoder().decode(GatewayMarkAllReadResponseDTO.self, from: data)
        #expect(decoded.marked == 7)
        #expect(decoded.boundaries.first?.entryId == "at://did/site.standard.document/latest")
        #expect(decoded.unreadCounts["at://did/site.standard.publication/main"] == 0)
    }
}
