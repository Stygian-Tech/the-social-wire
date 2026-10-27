import Foundation
import Testing
@testable import SocialWire

@Suite("Reader session ownership")
@MainActor
struct ReaderSessionIdentityTests {
    private func session() -> AuthSession {
        AuthSession(did: "did:plc:reader-\(UUID().uuidString)", pdsURL: URL(string: "https://pds.example.test")!,
            tokenEndpoint: URL(string: "https://issuer.example/token")!, accessToken: "access",
            refreshToken: "refresh", tokenType: "DPoP", scope: ATProtoOAuthService.scopes,
            expiresAt: .distantFuture)
    }

    @Test("Token rotation keeps the reader request owner")
    func tokenRefresh() {
        let original = session()
        let login = UUID()
        let identity = ReaderSessionIdentity(session: original, loginIdentity: login)
        var refreshed = original
        refreshed.accessToken = "rotated-access"
        refreshed.refreshToken = "rotated-refresh"
        refreshed.expiresAt = Date().addingTimeInterval(3600)
        #expect(identity.matches(session: refreshed, loginIdentity: login))
    }

    @Test("Changing the viewer or OAuth endpoints replaces the reader request owner", arguments: ["did", "pds", "issuer"])
    func accountReplacement(component: String) {
        var replacement = session()
        let login = UUID()
        let identity = ReaderSessionIdentity(session: replacement, loginIdentity: login)
        switch component {
        case "did": replacement.did = "did:plc:other"
        case "pds": replacement.pdsURL = URL(string: "https://replacement-pds.example.test")!
        default: replacement.tokenEndpoint = URL(string: "https://replacement-issuer.example/token")!
        }
        #expect(!identity.matches(session: replacement, loginIdentity: login))
    }

    @Test("Sign out and a new login invalidate ownership even for the same DID")
    func explicitLoginReplacement() {
        let original = session()
        let login = UUID()
        let identity = ReaderSessionIdentity(session: original, loginIdentity: login)
        #expect(!identity.matches(session: nil, loginIdentity: login))
        #expect(!identity.matches(session: original, loginIdentity: UUID()))
        let signedOut = ReaderSessionIdentity(session: nil, loginIdentity: login)
        #expect(!signedOut.matches(session: original, loginIdentity: login))
    }

    @Test("A same-DID endpoint replacement rejects an in-flight reader response", arguments: [true, false])
    func lateFeedResponse(changesPDS: Bool) async throws {
        let store = OAuthTestSessionStore()
        let auth = ATProtoOAuthService(keychain: store)
        let original = session()
        try await restore(original, auth: auth, store: store)
        let transport = ReaderFeedPendingTransport()
        let model = SocialWireAppModel(authService: auth,
            gatewayTransport: { try await transport.send($0) }, initialReaderListSource: .subscribed)
        defer { model.signOut() }
        model.feedSelection = .topLevel(.subscribed)
        model.readerFilter = .all
        let pending = Task { await model.selectFolderFeed(folderRkey: "before-replacement") }
        await transport.waitForRequests(1)
        var replacement = original
        if changesPDS {
            replacement.pdsURL = URL(string: "https://replacement-pds.example.test")!
        } else {
            replacement.tokenEndpoint = URL(string: "https://replacement-issuer.example/token")!
        }
        try await restore(replacement, auth: auth, store: store)
        let entry = EntryListItem(entryId: "old-private-article", title: "Old Article", summary: nil,
            publishedAt: "2026-10-26T00:00:00Z", thumbnailUrl: nil, thumbnailFallbackUrl: nil)
        let body = String(decoding: try JSONEncoder().encode(AppViewEntryListResponse(entries: [entry], cursor: "old-cursor")), as: UTF8.self)
        await transport.complete(0, body: body)
        await pending.value
        #expect(model.entries.isEmpty)
        #expect(!model.isLoading)
        #expect(!model.canLoadMoreEntries)
    }

    private func restore(_ session: AuthSession, auth: ATProtoOAuthService, store: OAuthTestSessionStore) async throws {
        let record: [String: Any] = [
            "session": try JSONSerialization.jsonObject(with: JSONEncoder().encode(session)),
            "dpopPrivateKey": Data(repeating: 1, count: 32).base64EncodedString(),
            "clientID": ATProtoOAuthConfig.clientID
        ]
        store.set(try JSONSerialization.data(withJSONObject: record).base64EncodedString(), for: "oauth.session.v2")
        await auth.restoreSession()
    }
}
