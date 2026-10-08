import Foundation
import Testing
@testable import SocialWire

struct StandardReaderListTests {
    private let uri = "at://did:plc:creator/app.standard-reader.list/abc"
    @Test func canonicalListIdentityRejectsOtherCollectionsAndWebLinks() throws {
        #expect(StandardReaderListContract.recordURI(" \(uri) ") == uri)
        #expect(StandardReaderListContract.recordURI("https://standard-reader.app/l/did:plc:creator/abc") == nil)
        #expect(StandardReaderListContract.recordURI(uri.replacingOccurrences(of: "app.standard-reader.list", with: "site.standard.publication")) == nil)
        #expect(StandardReaderListContract.recordURI(uri + "/extra") == nil)
        #expect(try StandardReaderListContract.saveKey(uri).count == 64)
        #expect(try StandardReaderListContract.saveKey(" \(uri) ") == StandardReaderListContract.saveKey(uri))
    }
    @Test func listRecordValidatesLimitsAndCanonicalPublicationReferences() throws {
        let publication = "at://did:plc:author/site.standard.publication/site"
        let value = try StandardReaderListContract.makeRecord(name: " Reader Picks ", description: " Curated ", publications: [publication], users: ["did:plc:author"])
        #expect(value.name == "Reader Picks")
        #expect(value.description == "Curated")
        #expect(throws: (any Error).self) { try StandardReaderListContract.makeRecord(name: String(repeating: "a", count: 65), description: "", publications: [], users: []) }
        #expect(throws: (any Error).self) { try StandardReaderListContract.makeRecord(name: "List", description: "", publications: ["https://example.com"], users: []) }
        #expect(throws: (any Error).self) { try StandardReaderListContract.makeRecord(name: "List", description: "", publications: [], users: ["author.example"]) }
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any]
        #expect(object?["$type"] as? String == "app.standard-reader.list")
    }
    @Test func partialPageRetainsPreviouslyLoadedLists() {
        let first = StandardReaderList(uri: uri, name: "One", creatorDid: "did:plc:creator", publications: [], users: [], owned: true, saved: false)
        var second = first; second.name = "Updated"
        let partial = StandardReaderListsPage(lists: [], refreshedAt: "now", complete: false)
        #expect(partial.merging(previous: [first]) == [first])
        #expect(StandardReaderListsPage(lists: [second], refreshedAt: "now", complete: false).merging(previous: [first]) == [second])
        #expect(StandardReaderListsPage(lists: [], refreshedAt: "now", complete: true).merging(previous: [first]).isEmpty)
    }
}

@Suite("Lists Navigation State")
@MainActor
struct StandardReaderListsModelTests {
    @Test("Pagination arriving while article detail is loading preserves the selected article")
    func paginationKeepsInFlightDetail() async throws {
        let store = OAuthTestSessionStore()
        let session = AuthSession(did: "did:plc:test", pdsURL: URL(string: "https://pds.example.test")!,
            tokenEndpoint: URL(string: "https://issuer.example/token")!, accessToken: "access",
            refreshToken: "refresh", tokenType: "DPoP", scope: ATProtoOAuthService.scopes, expiresAt: .distantFuture)
        let saved: [String: Any] = [
            "session": try JSONSerialization.jsonObject(with: JSONEncoder().encode(session)),
            "dpopPrivateKey": Data(repeating: 1, count: 32).base64EncodedString(),
            "clientID": ATProtoOAuthConfig.clientID,
        ]
        store.set(try JSONSerialization.data(withJSONObject: saved).base64EncodedString(), for: "oauth.session.v2")
        let auth = ATProtoOAuthService(keychain: store)
        await auth.restoreSession()
        defer { auth.signOut() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ListsPaginationURLProtocol.self]
        let gateway = SocialWireGatewayClient(auth: auth, baseURL: URL(string: "https://lists-fixture.invalid")!,
                                             urlSession: URLSession(configuration: configuration))
        let model = StandardReaderListsModel(gateway: gateway, xrpc: XRPCClient(auth: auth, resolver: ATProtoResolver()))
        model.bind(viewer: session.did)
        let list = StandardReaderList(uri: "at://did:plc:test/app.standard-reader.list/list", name: "List",
                                      creatorDid: session.did, publications: [], users: [], owned: true, saved: false)
        await model.select(list)
        let item = try #require(model.entries.first)
        #expect(model.cursor == "page-two")
        let opening = Task { await model.openEntry(item) }
        await ListsPaginationURLProtocol.state.waitForDetail()
        await model.loadFeed(nextPage: true)
        #expect(model.entries.count == 2)
        #expect(model.isLoadingEntry)
        ListsPaginationURLProtocol.state.releaseDetail()
        await opening.value
        #expect(model.selectedEntry?.entryId == item.entryId)
        #expect(!model.isLoadingEntry)
        #expect(model.entryError == nil)

        // A full refresh still invalidates the earlier detail request.
        let reopening = Task { await model.openEntry(item) }
        await ListsPaginationURLProtocol.state.waitForDetail()
        await model.loadFeed()
        ListsPaginationURLProtocol.state.releaseDetail()
        await reopening.value
        #expect(model.selectedEntry == nil)
        #expect(!model.isLoadingEntry)
    }

    @Test("Switching accounts clears list membership, feed rows, and open article")
    func accountReset() async {
        let auth = ATProtoOAuthService()
        let model = StandardReaderListsModel(gateway: SocialWireGatewayClient(auth: auth), xrpc: XRPCClient(auth: auth, resolver: ATProtoResolver()))
        let list = StandardReaderList(uri: "at://did:plc:viewer/app.standard-reader.list/list", name: "List", creatorDid: "did:plc:viewer", publications: [], users: [], owned: true, saved: true)
        let entry = EntryListItem(entryId: "at://did:plc:author/site.standard.document/article", title: "Article", summary: nil, publishedAt: "2026-10-08T00:00:00Z", thumbnailUrl: nil, thumbnailFallbackUrl: nil)
        model.configureFixture(lists: [list], entries: [entry])
        await model.select(list)
        await model.openEntry(entry)
        #expect(model.selectedList?.uri == list.uri)
        #expect(model.selectedEntry?.entryId == entry.entryId)
        model.bind(viewer: "did:plc:other")
        #expect(model.lists.isEmpty)
        #expect(model.entries.isEmpty)
        #expect(model.selectedList == nil)
        #expect(model.selectedEntry == nil)
        #expect(!model.isLoadingEntry)
    }
}

@Suite("Lists PDS Contract")
@MainActor
struct StandardReaderListWritesTests {
    private let viewer = "did:plc:test"
    private let uri = "at://did:plc:author/app.standard-reader.list/list"

    @Test("Saving writes canonical listSave on the PDS and completes the nonce retry")
    func nonceRetrySave() async throws {
        let transport = OAuthTestTransport([
            .init(status: 200, body: #"{"records":[]}"#),
            .init(status: 401, body: #"{"error":"use_dpop_nonce"}"#, headers: ["DPoP-Nonce": "lists-nonce"]),
            .init(status: 200, body: #"{"uri":"at://did:plc:test/app.standard-reader.listSave/key","cid":"cid"}"#),
        ])
        let (auth, service, _) = try await fixture(transport)
        defer { auth.signOut() }
        try await service.save(uri, viewer: viewer)
        let requests = await transport.recordedRequests()
        #expect(requests.count == 3)
        #expect(requests.allSatisfy { $0.url?.host == "pds.example.test" })
        let body = try #require(requests.last?.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["collection"] as? String == "app.standard-reader.listSave")
        let expectedKey = try StandardReaderListContract.saveKey(uri)
        #expect(object["rkey"] as? String == expectedKey)
        let record = try #require(object["record"] as? [String: Any])
        #expect(record["$type"] as? String == "app.standard-reader.listSave")
        #expect(record["list"] as? String == uri)
        #expect(requests.last?.value(forHTTPHeaderField: "DPoP") != requests[1].value(forHTTPHeaderField: "DPoP"))
    }

    @Test("Expected viewer rejects creation before any PDS write")
    func accountMismatchDoesNotWrite() async throws {
        let transport = OAuthTestTransport([])
        let (auth, _, xrpc) = try await fixture(transport)
        defer { auth.signOut() }
        let record = try StandardReaderListContract.makeRecord(name: "List", description: "", publications: [], users: [])
        do {
            _ = try await xrpc.createRecord(collection: StandardReaderListContract.collection, record: record, expectedViewer: "did:plc:other")
            Issue.record("Expected account mismatch")
        } catch {}
        #expect(await transport.recordedRequests().isEmpty)
    }

    @Test("Deleting another creator's list rejects before any PDS request")
    func ownershipCheck() async throws {
        let transport = OAuthTestTransport([])
        let (auth, service, _) = try await fixture(transport)
        defer { auth.signOut() }
        do {
            try await service.delete(uri, viewer: viewer)
            Issue.record("Expected ownership rejection")
        } catch {}
        #expect(await transport.recordedRequests().isEmpty)
    }

    private func fixture(_ transport: OAuthTestTransport) async throws -> (ATProtoOAuthService, StandardReaderListPDSService, XRPCClient) {
        let store = OAuthTestSessionStore()
        let session = AuthSession(did: viewer, pdsURL: URL(string: "https://pds.example.test")!,
            tokenEndpoint: URL(string: "https://issuer.example/token")!, accessToken: "access",
            refreshToken: "refresh", tokenType: "DPoP", scope: ATProtoOAuthService.scopes, expiresAt: .distantFuture)
        let record: [String: Any] = [
            "session": try JSONSerialization.jsonObject(with: JSONEncoder().encode(session)),
            "dpopPrivateKey": Data(repeating: 1, count: 32).base64EncodedString(),
            "clientID": ATProtoOAuthConfig.clientID,
        ]
        store.set(try JSONSerialization.data(withJSONObject: record).base64EncodedString(), for: "oauth.session.v2")
        let auth = ATProtoOAuthService(keychain: store, tokenTransport: { try await transport.send($0) })
        await auth.restoreSession()
        let xrpc = XRPCClient(auth: auth, resolver: ATProtoResolver(), transport: { try await transport.send($0) })
        return (auth, StandardReaderListPDSService(xrpc: xrpc), xrpc)
    }
}

/// Holds detail until the test completes pagination; response ordering never depends on a sleep.
private final class ListsPaginationFixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private var detail: ListsPaginationURLProtocol?
    private var waiter: CheckedContinuation<Void, Never>?

    func holdDetail(_ request: ListsPaginationURLProtocol) {
        let waiting = lock.withLock {
            detail = request
            let waiting = waiter
            waiter = nil
            return waiting
        }
        waiting?.resume()
    }

    func waitForDetail() async {
        await withCheckedContinuation { continuation in
            let alreadyReceived = lock.withLock {
                if detail != nil { return true }
                waiter = continuation
                return false
            }
            if alreadyReceived { continuation.resume() }
        }
    }

    func releaseDetail() {
        let request = lock.withLock {
            let request = detail
            detail = nil
            return request
        }
        request?.respond(#"{"entryId":"at://did:plc:author/site.standard.document/one","title":"One","publishedAt":"2026-10-08T00:00:00Z","contentHtml":"<p>Article</p>"}"#)
    }
}

private final class ListsPaginationURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = ListsPaginationFixtureState()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "lists-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.path.hasSuffix("getEntry") == true {
            Self.state.holdDetail(self)
            return
        }
        let cursor = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "cursor" }?.value
        if cursor == nil {
            respond(#"{"entries":[{"entryId":"at://did:plc:author/site.standard.document/one","title":"One","publishedAt":"2026-10-08T00:00:00Z"}],"cursor":"page-two"}"#)
        } else {
            respond(#"{"entries":[{"entryId":"at://did:plc:author/site.standard.document/two","title":"Two","publishedAt":"2026-10-08T00:00:00Z"}]}"#)
        }
    }
    func respond(_ body: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
