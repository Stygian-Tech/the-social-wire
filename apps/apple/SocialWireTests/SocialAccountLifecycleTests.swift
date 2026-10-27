import Foundation
import Testing
@testable import SocialWire

@Suite("Social account lifecycle")
@MainActor
struct SocialAccountLifecycleTests {
    private func restore(_ did: String, auth: ATProtoOAuthService, store: OAuthTestSessionStore) async throws {
        let session = AuthSession(did: did, pdsURL: URL(string: "https://pds.example.test")!,
            tokenEndpoint: URL(string: "https://issuer.example/token")!, accessToken: "access",
            refreshToken: "refresh", tokenType: "DPoP", scope: ATProtoOAuthService.scopes, expiresAt: .distantFuture)
        let record: [String: Any] = [
            "session": try JSONSerialization.jsonObject(with: JSONEncoder().encode(session)),
            "dpopPrivateKey": Data(repeating: 1, count: 32).base64EncodedString(),
            "clientID": ATProtoOAuthConfig.clientID
        ]
        store.set(try JSONSerialization.data(withJSONObject: record).base64EncodedString(), for: "oauth.session.v2")
        await auth.restoreSession()
    }

    @Test("Account changes replace social state while same-account refresh preserves it")
    func workspaceOwnership() async throws {
        let store = OAuthTestSessionStore()
        let auth = ATProtoOAuthService(keychain: store)
        try await restore("did:plc:alice", auth: auth, store: store)
        let transport = OAuthTestTransport([
            .init(status: 200, body: #"{"convos":[{"id":"alice-private-conversation","members":[],"unreadCount":1,"muted":false}]}"#)
        ])
        let model = SocialWireAppModel(authService: auth, xrpcTransport: { try await transport.send($0) })
        let aliceWorkspace = model.social
        await aliceWorkspace.messages.refreshConversations()
        #expect(aliceWorkspace.messages.conversations.map(\.id) == ["alice-private-conversation"])
        try await restore("did:plc:alice", auth: auth, store: store)
        #expect(model.social === aliceWorkspace)

        try await restore("did:plc:bob", auth: auth, store: store)
        #expect(model.social !== aliceWorkspace)
        #expect(model.social.messages !== aliceWorkspace.messages)
        #expect(model.social.messages.messages.isEmpty)
        #expect(model.social.messages.conversations.isEmpty)
        #expect(model.social.timeline.posts.isEmpty)
        let bobWorkspace = model.social
        model.signOut()
        #expect(model.social !== bobWorkspace)
        try await restore("did:plc:bob", auth: auth, store: store)
        #expect(model.social !== bobWorkspace)
        model.signOut()
    }

    @Test("An invalidated client cannot write through a later session with the same DID")
    func invalidatedWrite() async throws {
        let store = OAuthTestSessionStore()
        let auth = ATProtoOAuthService(keychain: store)
        try await restore("did:plc:alice", auth: auth, store: store)
        let scope = SocialSessionScope(viewerDID: auth.session?.did, auth: auth)
        let underlying = OAuthTestTransport([.init(status: 200, body: #"{"uri":"at://did:plc:alice/app.bsky.graph.follow/test","cid":"cid"}"#)])
        let xrpc = XRPCClient(auth: auth, resolver: ATProtoResolver(), transport: scope.transport(using: { try await underlying.send($0) }))
        let client = SocialWireSocialClient(xrpc: xrpc, publicationService: PublicationService(xrpc: xrpc))
        scope.invalidate()
        auth.signOut()
        try await restore("did:plc:alice", auth: auth, store: store)
        await #expect(throws: CancellationError.self) {
            _ = try await client.follow(did: "did:plc:target")
        }
        #expect(await underlying.recordedRequests().isEmpty)
        auth.signOut()
    }

    @Test("A non-cooperative old request cannot return private data after account departure")
    func lateResponse() async throws {
        let store = OAuthTestSessionStore()
        let auth = ATProtoOAuthService(keychain: store)
        try await restore("did:plc:alice", auth: auth, store: store)
        let scope = SocialSessionScope(viewerDID: auth.session?.did, auth: auth)
        let underlying = SocialAccountPendingTransport()
        let transport = scope.transport(using: { try await underlying.send($0) })
        let request = URLRequest(url: URL(string: "https://pds.example.test/xrpc/chat.bsky.convo.listConvos")!)
        let pending = Task { try await transport(request) }
        await underlying.waitForRequest()
        scope.invalidate()
        auth.signOut()
        try await restore("did:plc:bob", auth: auth, store: store)
        await underlying.complete()
        await #expect(throws: CancellationError.self) { _ = try await pending.value }
        auth.signOut()
    }
}
