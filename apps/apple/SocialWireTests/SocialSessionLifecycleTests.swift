import Foundation
import Testing
@testable import SocialWire

@Suite("Native Social Session Lifecycle")
@MainActor
struct SocialSessionLifecycleTests {
    private func fixture() async throws -> (SocialWorkspaceModel, SocialSessionTransport, AuthSession) {
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
        let transport = SocialSessionTransport()
        let xrpc = XRPCClient(auth: auth, resolver: ATProtoResolver(), transport: { try await transport.send($0) })
        let model = SocialWorkspaceModel(xrpc: xrpc, publicationService: PublicationService(xrpc: xrpc),
            gateway: SocialWireGatewayClient(auth: auth))
        auth.setSessionChangeHandler { model.bind(session: $0) }
        return (model, transport, session)
    }

    @Test("Same-DID replacement clears private conversations and stale selection")
    func replacementClearsMessages() async throws {
        let (model, transport, session) = try await fixture()
        let load = Task { await model.messages.refreshConversations() }
        await transport.waitForRequest()
        await transport.complete(.success(#"{"convos":[{"id":"private","members":[],"unreadCount":2,"muted":false}]}"#))
        await load.value
        #expect(model.messages.conversations.count == 1)
        #expect(model.messages.viewerDID == session.did)
        let oldID = model.sessionID
        var replacement = session
        replacement.accessToken = "replacement"
        model.bind(session: replacement)
        #expect(model.sessionID != oldID)
        #expect(model.messages.conversations.isEmpty)
        #expect(model.messages.messages.isEmpty)
        #expect(model.messages.viewerDID == nil)
        #expect(model.messages.selectedConversationID == nil)
        let unchanged = model.sessionID
        model.bind(session: replacement)
        #expect(model.sessionID == unchanged)
    }

    @Test("A late conversation response cannot restore the departed viewer")
    func lateConversations() async throws {
        let (model, transport, _) = try await fixture()
        let load = Task { await model.messages.refreshConversations() }
        await transport.waitForRequest()
        model.bind(session: nil)
        await transport.complete(.success(#"{"convos":[{"id":"private","members":[],"unreadCount":2,"muted":false}]}"#))
        await load.value
        #expect(model.messages.conversations.isEmpty)
        #expect(model.messages.viewerDID == nil)
        #expect(!model.messages.isLoading)
        #expect(model.messages.error == nil)
    }

    @Test("Same-DID replacement fences a late message selection")
    func lateSelectedMessages() async throws {
        let (model, transport, session) = try await fixture()
        let conversation = SocialConversation(id: "private", members: [], lastMessage: nil, unreadCount: 0, muted: false, status: nil)
        let load = Task { await model.messages.select(conversation) }
        await transport.waitForRequest()
        var replacement = session
        replacement.accessToken = "replacement"
        model.bind(session: replacement)
        await transport.complete(.success(#"{"messages":[{"id":"secret","sender":{"did":"did:plc:other"},"text":"Private","sentAt":"2026-10-22T12:00:00Z"}]}"#))
        await load.value
        #expect(model.messages.messages.isEmpty)
        #expect(model.messages.selectedConversationID == nil)
        #expect(!model.messages.isLoading)
    }

    @Test("Late timeline failures cannot overwrite the next account's state")
    func lateTimelineFailure() async throws {
        let (model, transport, session) = try await fixture()
        let load = Task { await model.timeline.refresh() }
        await transport.waitForRequest()
        var replacement = session
        replacement.did = "did:plc:other"
        model.bind(session: replacement)
        await transport.complete(.failure(URLError(.notConnectedToInternet)))
        await load.value
        #expect(model.timeline.error == nil)
        #expect(model.timeline.posts.isEmpty)
        #expect(!model.timeline.isLoading)
        #expect(model.proEntitlement.viewerDID == replacement.did)
    }

    @Test("A late catalog response cannot restore departed account lists")
    func lateLists() async throws {
        let (model, transport, _) = try await fixture()
        let load = Task { await model.catalog.loadLists() }
        await transport.waitForRequest()
        model.bind(session: nil)
        await transport.complete(.success(#"{"lists":[{"uri":"at://did:plc:test/app.bsky.graph.list/a","cid":"cid","name":"Private","creator":{"did":"did:plc:test","handle":"test.example"},"purpose":"app.bsky.graph.defs#curatelist"}]}"#))
        await load.value
        #expect(model.catalog.lists.isEmpty)
        #expect(model.catalog.error == nil)
        #expect(!model.catalog.isLoading)
    }

    @Test("A like completing after refresh removes the row never uses its stale array index")
    func mutationAfterRefresh() async throws {
        let (model, transport, _) = try await fixture()
        let load = Task { await model.timeline.refresh() }
        await transport.waitForRequest()
        await transport.complete(.success(#"{"feed":[{"post":{"uri":"at://did:plc:test/app.bsky.feed.post/a","cid":"cid","author":{"did":"did:plc:test","handle":"test.example"},"record":{"text":"Post","createdAt":"2026-10-22T12:00:00Z"},"indexedAt":"2026-10-22T12:00:00Z"}}]}"#))
        await load.value
        let post = try #require(model.timeline.posts.first)
        let mutation = Task { await model.timeline.toggleLike(post) }
        await transport.waitForRequest()
        let refresh = Task { await model.timeline.refresh() }
        await transport.waitForRequest(count: 2)
        await transport.complete(.success(#"{"feed":[]}"#), index: 1)
        await refresh.value
        await transport.complete(.success(#"{"uri":"at://did:plc:test/app.bsky.feed.like/a","cid":"cid"}"#))
        await mutation.value
        #expect(model.timeline.posts.isEmpty)
        #expect(model.timeline.error == nil)
    }

    @Test("A message send cannot append into another selected conversation")
    func sendAfterSelectionChanges() async throws {
        let (model, transport, _) = try await fixture()
        let first = SocialConversation(id: "first", members: [], lastMessage: nil, unreadCount: 0, muted: false, status: nil)
        let second = SocialConversation(id: "second", members: [], lastMessage: nil, unreadCount: 0, muted: false, status: nil)
        let selectFirst = Task { await model.messages.select(first) }
        await transport.waitForRequest()
        await transport.complete(.success(#"{"messages":[]}"#))
        await selectFirst.value
        let send = Task { await model.messages.send("Private") }
        await transport.waitForRequest()
        let selectSecond = Task { await model.messages.select(second) }
        await transport.waitForRequest(count: 2)
        await transport.complete(.success(#"{"messages":[]}"#), index: 1)
        await selectSecond.value
        await transport.complete(.success(#"{"message":{"id":"sent","sender":{"did":"did:plc:test"},"text":"Private","sentAt":"2026-10-22T12:00:00Z"}}"#))
        #expect(await send.value == false)
        #expect(model.messages.messages.isEmpty)
        #expect(model.messages.selectedConversationID == "second")
    }

}

private actor SocialSessionTransport {
    private var pending: [(URLRequest, CheckedContinuation<(Data, URLResponse), Error>)] = []

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        // Intentionally ignores task cancellation so late-response fencing is exercised.
        return try await withCheckedThrowingContinuation { pending.append((request, $0)) }
    }

    func waitForRequest(count: Int = 1) async {
        while pending.count < count { await Task.yield() }
    }

    func complete(_ result: Result<String, Error>, index: Int = 0) {
        guard pending.indices.contains(index) else { return }
        let (request, continuation) = pending.remove(at: index)
        switch result {
        case .success(let body):
            continuation.resume(returning: (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: [:])!))
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}
