import Foundation
import ReadStateCore
import Testing
@testable import SocialWire

@Suite("PDSRecordService")
@MainActor
struct PDSRecordServiceTests {
    @Test("collection constants match lexicons")
    func collectionConstantsMatchLexicons() {
        #expect(PDSRecordService.folder == "app.thesocialwire.folder")
        #expect(PDSRecordService.publicationPrefs == "app.thesocialwire.publicationPrefs")
        #expect(PDSRecordService.preferences == "app.thesocialwire.preferences")
        #expect(PDSRecordService.latrSavedExternal == "link.latr.saved.external")
        #expect(PDSRecordService.latrSavedItem == "link.latr.saved.item")
        #expect(PDSRecordService.standardSiteSubscription == "site.standard.graph.subscription")
        #expect(PDSRecordService.standardSiteRecommend == "site.standard.graph.recommend")
        #expect(PDSRecordService.wireArticleFeedback == "app.thesocialwire.wireFeedback")
        #expect(PDSRecordService.skyreaderFeedSubscription == "app.skyreader.feed.subscription")
    }
    @Test("Checking authority never publishes an AppView user's read history")
    func authorityLookupDoesNotMigrate() async throws {
        let viewer = "did:plc:opt-in-test"
        let suite = "read-state-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let auth = ATProtoOAuthService()
        let xrpc = XRPCClient(auth: auth, resolver: ATProtoResolver())
        var engineCreations = 0
        let service = PDSReadStateSyncService(xrpc: xrpc, gateway: SocialWireGatewayClient(auth: auth), defaults: defaults,
            currentViewer: { viewer }, statusProvider: { _ in
                .init(authority: .appview, migrationState: .notStarted, legacyRevision: 42)
            }, engineProvider: { _ in engineCreations += 1; throw ReadStateSyncFailure.conflict })
        #expect(try await !service.ensureAuthority(viewer: viewer))
        #expect(engineCreations == 0)
        #expect(!service.isMigrating)
        #expect(service.authority == .appview)
    }

    @Test("An old account's late authority response cannot switch the new account")
    func authorityResponseIsAccountIsolated() async throws {
        let suite = "read-state-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let auth = ATProtoOAuthService()
        let xrpc = XRPCClient(auth: auth, resolver: ATProtoResolver())
        var viewer = "did:plc:account-a"
        var continuation: CheckedContinuation<PDSReadStateStatus, Never>?
        let service = PDSReadStateSyncService(xrpc: xrpc, gateway: SocialWireGatewayClient(auth: auth), defaults: defaults,
            currentViewer: { viewer }, statusProvider: { requested in
                if requested == "did:plc:account-a" {
                    return await withCheckedContinuation { continuation = $0 }
                }
                return .init(authority: .appview, migrationState: .notStarted, legacyRevision: 0)
            })
        let first = Task { try await service.ensureAuthority(viewer: "did:plc:account-a") }
        while continuation == nil { await Task.yield() }
        viewer = "did:plc:account-b"
        service.reset()
        #expect(try await !service.ensureAuthority(viewer: viewer))
        continuation?.resume(returning: .init(authority: .pds, migrationState: .verified, legacyRevision: 1))
        await #expect(throws: ReadStateSyncFailure.self) { try await first.value }
        #expect(service.authority == .appview)
        #expect(!service.isPDSAuthoritative)
    }

    @Test("Known PDS authority and pending unread survive foreground refresh and restart")
    func pendingUnreadSurvivesRefresh() async throws {
        let viewer = "did:plc:pending-test"
        let suite = "read-state-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appending(path: suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let auth = ATProtoOAuthService()
        let xrpc = XRPCClient(auth: auth, resolver: ATProtoResolver())
        let transport = ReadStateSyncTransport(readManifest: { throw URLError(.notConnectedToInternet) },
            loadProjection: { _ in throw URLError(.notConnectedToInternet) },
            putChunk: { _, _ in throw URLError(.notConnectedToInternet) },
            putManifest: { _, _ in throw URLError(.notConnectedToInternet) },
            confirm: { _, _ in throw URLError(.notConnectedToInternet) })
        var offline = false
        let service = PDSReadStateSyncService(xrpc: xrpc, gateway: SocialWireGatewayClient(auth: auth), defaults: defaults,
            currentViewer: { viewer }, statusProvider: { _ in
                if offline { throw URLError(.notConnectedToInternet) }
                return .init(authority: .pds, migrationState: .verified, legacyRevision: 2)
            }, engineProvider: { did in try ReadStateSyncEngine(viewerDid: did,
                file: directory.appending(path: "outbox.json"), transport: transport) })
        #expect(try await service.ensureAuthority(viewer: viewer))
        try await service.setExact(viewer: viewer, subjectUris: ["story"], state: .unread, actedAt: "2026-09-08T00:00:00Z")
        #expect(service.pendingExactOverrides["story"] == .unread)
        service.reset()
        offline = true
        #expect(try await service.ensureAuthority(viewer: viewer))
        #expect(service.pendingCount == 1)
        #expect(service.pendingExactOverrides["story"] == .unread)
        service.reset()
    }

    @Test("Native first migration accepts only exact RecordNotFound 400 as an absent manifest")
    func absentManifestTransportResponse() throws {
        let client = XRPCClient(auth: ATProtoOAuthService(), resolver: ATProtoResolver())
        let response = HTTPURLResponse(url: URL(string: "https://pds.example/xrpc/com.atproto.repo.getRecord")!,
            statusCode: 400, httpVersion: nil, headerFields: nil)!
        let absent: RepoRecord<ReadStateManifest>? = try client.decodeReadStateResponse(
            data: Data(#"{"error":"RecordNotFound","message":"Could not locate record"}"#.utf8), response: response,
            viewerDid: "did:plc:viewer", collection: ReadStateManifest.collection, rkey: "self")
        #expect(absent == nil)
        for data in [Data(#"{"error":"InvalidRequest","message":"Bad collection"}"#.utf8),
                     Data(#"{"error":"recordnotfound"}"#.utf8), Data("malformed".utf8)] {
            #expect(throws: (any Error).self) {
                let _: RepoRecord<ReadStateManifest>? = try client.decodeReadStateResponse(data: data, response: response,
                    viewerDid: "did:plc:viewer", collection: ReadStateManifest.collection, rkey: "self")
            }
        }
    }

    @Test("RecordNotFound body never hides denied access or a throttled PDS")
    func recordNotFoundDoesNotHideTransportFailures() throws {
        let client = XRPCClient(auth: ATProtoOAuthService(), resolver: ATProtoResolver())
        for status in [401, 403, 429, 500] {
            let response = HTTPURLResponse(url: URL(string: "https://pds.example/xrpc/com.atproto.repo.getRecord")!,
                statusCode: status, httpVersion: nil, headerFields: nil)!
            #expect(throws: (any Error).self) {
                let _: RepoRecord<ReadStateManifest>? = try client.decodeReadStateResponse(
                    data: Data(#"{"error":"RecordNotFound"}"#.utf8), response: response,
                    viewerDid: "did:plc:viewer", collection: ReadStateManifest.collection, rkey: "self")
            }
        }
    }

}
