import Foundation
import Testing
@testable import SocialWire

struct SocialCoreTests {
    @Test("Thread segments enforce grapheme and byte limits")
    func threadSegmentLimits() {
        #expect(SocialThreadDraftSegment(text: "Hello").isValid)
        #expect(!SocialThreadDraftSegment(text: "   ").isValid)
        #expect(!SocialThreadDraftSegment(text: String(repeating: "a", count: 301)).isValid)
        #expect(!SocialThreadDraftSegment(text: String(repeating: "👨‍👩‍👧‍👦", count: 300)).isValid)
    }

    @Test("Rapid thread segments receive unique sortable TIDs")
    func uniqueSegmentKeys() {
        let keys = (0..<1000).map { _ in SocialThreadDraftSegment(text: "Post").recordKey }
        #expect(Set(keys).count == keys.count)
        #expect(keys == keys.sorted())
        #expect(keys.allSatisfy { $0.count == 13 && $0.allSatisfy { "234567abcdefghijklmnopqrstuvwxyz".contains($0) } })
    }

    @Test("Social dates accept equivalent RFC 3339 forms")
    func socialDates() {
        let whole = SocialDate.parse("2026-10-14T12:30:00Z")
        let fractional = SocialDate.parse("2026-10-14T12:30:00.000Z")
        #expect(whole != nil)
        #expect(whole == fractional)
    }

    @Test("Notification identity remains stable across read changes")
    func notificationIdentity() {
        let author = SocialAuthor(did: "did:plc:alice", handle: "alice.test", displayName: "Alice", avatar: nil)
        let date = Date(timeIntervalSince1970: 100)
        var notification = SocialNotification(uri: "at://did:plc:alice/app.bsky.feed.like/a", cid: "cid", author: author, reason: "like", reasonSubject: nil, indexedAt: date, isRead: false, post: nil)
        let id = notification.id
        notification.isRead = true
        #expect(notification.id == id)
    }

    @Test("Pro entitlements remain bound to the server viewer")
    func proEntitlementDecoding() throws {
        let data = Data(#"{"viewerDid":"did:plc:alice","plan":"pro"}"#.utf8)
        let entitlement = try JSONDecoder().decode(SocialProEntitlement.self, from: data)
        #expect(entitlement.viewerDid == "did:plc:alice")
        #expect(entitlement.plan == .pro)
    }

    @Test("Only the Pro tools destination requires Pro")
    func proDestinationBoundary() {
        #expect(SocialDestination.proTools.requiresPro)
        #expect(SocialDestination.allCases.filter(\.requiresPro) == [.proTools])
    }
}

@Suite("Native Social Publishing Recovery")
@MainActor
struct SocialPublishingRecoveryTests {
    private func fixture(_ transport: SocialPublishingTransport) async throws -> (ATProtoOAuthService, SocialWireSocialClient) {
        let store = OAuthTestSessionStore()
        let auth = ATProtoOAuthService(keychain: store)
        let session = AuthSession(did: "did:plc:test", pdsURL: URL(string: "https://pds.example.test")!,
            tokenEndpoint: URL(string: "https://issuer.example/token")!, accessToken: "access",
            refreshToken: "refresh", tokenType: "DPoP", scope: ATProtoOAuthService.scopes, expiresAt: .distantFuture)
        let saved: [String: Any] = [
            "session": try JSONSerialization.jsonObject(with: JSONEncoder().encode(session)),
            "dpopPrivateKey": Data(repeating: 1, count: 32).base64EncodedString(),
            "clientID": ATProtoOAuthConfig.clientID,
        ]
        store.set(try JSONSerialization.data(withJSONObject: saved).base64EncodedString(), for: "oauth.session.v2")
        await auth.restoreSession()
        let xrpc = XRPCClient(auth: auth, resolver: ATProtoResolver(), transport: { try await transport.send($0) })
        return (auth, SocialWireSocialClient(xrpc: xrpc, publicationService: PublicationService(xrpc: xrpc)))
    }

    @Test("Retry resumes from the last confirmed thread parent")
    func threadRetryPreservesChain() async throws {
        let transport = SocialPublishingTransport(failBeforeCommit: 2)
        let (_, client) = try await fixture(transport)
        let model = SocialComposerModel(client: client)
        model.segments = [.init(text: "First"), .init(text: "Second"), .init(text: "Third")]
        #expect(await model.publish() == false)
        #expect(model.completed == 1)
        #expect(await model.publish())
        let records = await transport.publishedRecords()
        #expect(records.count == 3)
        let root = try #require(model.segments[0].published)
        let second = try #require(model.segments[1].published)
        #expect(records[1]["reply"] == .object([
            "root": .object(["uri": .string(root.uri), "cid": .string(root.cid)]),
            "parent": .object(["uri": .string(root.uri), "cid": .string(root.cid)])]))
        #expect(records[2]["reply"] == .object([
            "root": .object(["uri": .string(root.uri), "cid": .string(root.cid)]),
            "parent": .object(["uri": .string(second.uri), "cid": .string(second.cid)])]))
    }

    @Test("A lost create response is reconciled without posting twice")
    func lostResponseReadback() async throws {
        let transport = SocialPublishingTransport(loseResponse: true)
        let (_, client) = try await fixture(transport)
        let model = SocialComposerModel(client: client)
        model.segments[0].text = "Only Once"
        #expect(await model.publish())
        #expect(model.completed == 1)
        #expect(await transport.createCount == 1)
        #expect(await model.publish())
        #expect(await transport.createCount == 1)
    }

    @Test("An unresolved first attempt keeps its key and locks editing")
    func failedAttemptKeepsKey() async throws {
        let transport = SocialPublishingTransport(failBeforeCommit: 1)
        let (_, client) = try await fixture(transport)
        let model = SocialComposerModel(client: client)
        model.segments[0].text = "Stable Draft"
        let key = model.segments[0].recordKey
        #expect(await model.publish() == false)
        #expect(model.isLocked)
        model.addSegment()
        #expect(model.segments.count == 1)
        #expect(await model.publish())
        #expect(model.segments[0].published?.uri.hasSuffix("/\(key)") == true)
    }

    @Test("A different payload at a reserved key is never overwritten")
    func conflictingRecordIsPreserved() async throws {
        let transport = SocialPublishingTransport()
        let (_, client) = try await fixture(transport)
        let model = SocialComposerModel(client: client)
        model.segments[0].text = "Original"
        var snapshot = model.segments[0]
        #expect(await model.publish())
        snapshot.text = "Changed"
        let retry = SocialComposerModel(client: client)
        retry.segments = [snapshot]
        #expect(await retry.publish() == false)
        #expect(await transport.createCount == 1)
        #expect(await transport.publishedRecords().first?["text"] == .string("Original"))
    }

    @Test("A composer opened for another session cannot publish")
    func signedOutComposerCannotPublishAfterLogin() async throws {
        let transport = SocialPublishingTransport()
        let (auth, client) = try await fixture(transport)
        let model = SocialComposerModel(client: client)
        model.segments[0].text = "Private Draft"
        auth.signOut()
        #expect(await model.publish() == false)
        #expect(await transport.createCount == 0)
    }
}

private actor SocialPublishingTransport {
    private var records: [String: [String: JSONValue]] = [:]
    private var order: [String] = []
    private let failBeforeCommit: Int?
    private var loseResponse: Bool
    private(set) var createCount = 0

    init(failBeforeCommit: Int? = nil, loseResponse: Bool = false) {
        self.failBeforeCommit = failBeforeCommit
        self.loseResponse = loseResponse
    }

    func publishedRecords() -> [[String: JSONValue]] { order.compactMap { records[$0] } }

    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        let url = request.url!
        var status = 200
        var body: [String: Any] = [:]
        if url.path.hasSuffix("getRecord") {
            let key = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "rkey" }!.value!
            if let record = records[key] {
                body = ["uri": "at://did:plc:test/app.bsky.feed.post/\(key)", "cid": "cid-\(key)",
                        "value": try JSONSerialization.jsonObject(with: JSONEncoder().encode(record))]
            } else { status = 404 }
        } else if url.path.hasSuffix("createRecord") {
            createCount += 1
            if createCount == failBeforeCommit { throw URLError(.timedOut) }
            let object = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let key = object["rkey"] as! String
            #expect(records[key] == nil)
            records[key] = try JSONDecoder().decode([String: JSONValue].self, from: JSONSerialization.data(withJSONObject: object["record"]!))
            order.append(key)
            if loseResponse { loseResponse = false; throw URLError(.networkConnectionLost) }
            body = ["uri": "at://did:plc:test/app.bsky.feed.post/\(key)", "cid": "cid-\(key)"]
        }
        return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
