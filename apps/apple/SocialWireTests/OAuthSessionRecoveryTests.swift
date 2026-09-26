import Foundation
import Testing
@testable import SocialWire

@Suite("OAuth credential recovery")
@MainActor
struct OAuthSessionRecoveryTests {
    private static let success = OAuthTestTransport.Reply(status: 200, body:
        #"{"access_token":"new-access","refresh_token":"new-refresh","token_type":"DPoP","expires_in":3600}"#)
    private let pdsURL = URL(string: "https://pds.example.test")!

    @Test("explicit client bindings migrate; unknown and Beta bindings require sign-in")
    func clientBindingMigration() async throws {
        let payload = try JSONSerialization.data(withJSONObject: ["client_id": ATProtoOAuthConfig.clientID])
            .base64URLEncodedString()
        for (binding, token, shouldRestore) in [
            (Optional(ATProtoOAuthConfig.clientID), "opaque", true),
            (nil, "header.\(payload).signature", true),
            (nil, "opaque", false),
            (Optional("https://other.example/ios-client-metadata.json"), "opaque", false),
        ] {
            let keychain = OAuthTestSessionStore()
            let transport = OAuthTestTransport([])
            let auth = ATProtoOAuthService(keychain: keychain, tokenTransport: { try await transport.send($0) })
            defer { auth.signOut() }
            try seed(keychain, accessToken: token, binding: binding)
            await auth.restoreSession()
            #expect((auth.session != nil) == shouldRestore)
            #expect(auth.reauthorizationRequired == !shouldRestore)
            #expect(await transport.recordedRequests().isEmpty)
            if shouldRestore {
                let raw = try #require(keychain.string(for: "oauth.session.v2"))
                let record = try #require(JSONSerialization.jsonObject(with: Data(base64Encoded: raw)!) as? [String: Any])
                #expect(record["clientID"] as? String == ATProtoOAuthConfig.clientID)
            }
        }
    }

    @Test("legacy separate keys migrate only with an explicit matching token client ID")
    func legacyKeyMigration() async throws {
        let keychain = OAuthTestSessionStore()
        let transport = OAuthTestTransport([])
        let auth = ATProtoOAuthService(keychain: keychain, tokenTransport: { try await transport.send($0) })
        defer { auth.signOut() }
        let payload = try JSONSerialization.data(withJSONObject: ["client_id": ATProtoOAuthConfig.clientID])
            .base64URLEncodedString()
        for (key, value) in [
            ("oauth.did", "did:plc:test"), ("oauth.refreshToken", "legacy-refresh"),
            ("oauth.accessToken", "header.\(payload).signature"), ("oauth.pdsURL", pdsURL.absoluteString),
            ("oauth.tokenEndpoint", "https://issuer.example/token"),
            ("oauth.expiresAt", String(Date.distantFuture.timeIntervalSince1970)),
            ("oauth.dpopKey", Data(repeating: 1, count: 32).base64EncodedString()),
        ] { keychain.set(value, for: key) }
        await auth.restoreSession()
        #expect(auth.session?.refreshToken == "legacy-refresh")
        #expect(keychain.string(for: "oauth.session.v2") != nil)
        #expect(await transport.recordedRequests().isEmpty)
    }

    @Test("transient refresh failures retain credentials while invalid grants require sign-in")
    func refreshFailurePolicy() async throws {
        for (reply, definitive) in [
            (OAuthTestTransport.Reply(status: 503, body: #"{"error":"temporarily_unavailable"}"#), false),
            (.init(status: 400, body: #"{"error":"invalid_grant"}"#), true),
        ] {
            let keychain = OAuthTestSessionStore()
            let transport = OAuthTestTransport([reply])
            let auth = ATProtoOAuthService(keychain: keychain, tokenTransport: { try await transport.send($0) })
            defer { auth.signOut() }
            try seed(keychain, expiresAt: .distantPast)
            await auth.restoreSession()
            #expect((auth.session == nil) == definitive)
            #expect(auth.reauthorizationRequired == definitive)
            #expect((keychain.string(for: "oauth.session.v2") == nil) == definitive)
        }
        let keychain = OAuthTestSessionStore()
        let offline = OAuthTestTransport([])
        let auth = ATProtoOAuthService(keychain: keychain, tokenTransport: { try await offline.send($0) })
        defer { auth.signOut() }
        try seed(keychain, expiresAt: .distantPast)
        await auth.restoreSession()
        #expect(auth.session != nil && !auth.reauthorizationRequired)
    }

    @Test("concurrent recovery refreshes once and Sign Out fences late refresh completion")
    func coalescedRefreshAndSignOut() async throws {
        let keychain = OAuthTestSessionStore()
        let transport = OAuthTestTransport([Self.success, Self.success], delay: .milliseconds(40))
        let auth = ATProtoOAuthService(keychain: keychain, tokenTransport: { try await transport.send($0) })
        defer { auth.signOut() }
        try seed(keychain)
        await auth.restoreSession()
        let rejected = try #require(auth.session)
        async let first = auth.refreshedSession(rejected: rejected)
        async let second = auth.refreshedSession(rejected: rejected)
        let sessions = try await [first, second]
        #expect(sessions.allSatisfy { $0.accessToken == "new-access" })
        #expect(await transport.recordedRequests().count == 1)
        let request = try #require(await transport.recordedRequests().first)
        let form = String(data: request.httpBody!, encoding: .utf8)!
        var components = URLComponents()
        components.percentEncodedQuery = form
        #expect(components.queryItems?.first { $0.name == "client_id" }?.value == ATProtoOAuthConfig.clientID)
        let refreshed = try #require(auth.session)
        let pending = Task { try await auth.refreshedSession(rejected: refreshed) }
        while await transport.recordedRequests().count < 2 { await Task.yield() }
        auth.signOut()
        _ = try? await pending.value
        #expect(auth.session == nil)
        #expect(keychain.string(for: "oauth.session.v2") == nil)
    }

    @Test("PDS invalid-token recovery preserves nonce retries and re-signs with the refreshed token")
    func resourceRecovery() async throws {
        let keychain = OAuthTestSessionStore()
        let tokens = OAuthTestTransport([Self.success])
        let auth = ATProtoOAuthService(keychain: keychain, tokenTransport: { try await tokens.send($0) })
        defer { auth.signOut() }
        try seed(keychain)
        await auth.restoreSession()
        let resource = OAuthTestTransport([
            .init(status: 401, body: #"{"error":"use_dpop_nonce"}"#, headers: ["DPoP-Nonce": "one"]),
            .init(status: 401, body: #"{"error":"ExpiredToken"}"#),
            .init(status: 200, body: #"{"uri":"at://did:plc:test/test/one","cid":"cid","value":{}}"#),
        ])
        let xrpc = XRPCClient(auth: auth, resolver: ATProtoResolver(), transport: { try await resource.send($0) })
        let record: RepoRecord<[String: String]>? = try await xrpc.authorizedRepoGetRecord(collection: "test", rkey: "one")
        #expect(record?.cid == "cid")
        let requests = await resource.recordedRequests()
        #expect(requests.count == 3)
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "DPoP old-access")
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "DPoP old-access")
        #expect(requests[2].value(forHTTPHeaderField: "Authorization") == "DPoP new-access")
        #expect(requests[0].value(forHTTPHeaderField: "DPoP") != requests[1].value(forHTTPHeaderField: "DPoP"))
        #expect(await tokens.recordedRequests().count == 1)
    }

    @Test("second invalid token requires sign-in but nonce exhaustion does not refresh or log out")
    func boundedResourceFailure() async throws {
        for invalidToken in [true, false] {
            let keychain = OAuthTestSessionStore()
            let tokens = OAuthTestTransport([Self.success])
            let auth = ATProtoOAuthService(keychain: keychain, tokenTransport: { try await tokens.send($0) })
            defer { auth.signOut() }
            try seed(keychain)
            await auth.restoreSession()
            let reply = OAuthTestTransport.Reply(status: 401,
                body: invalidToken ? #"{"error":"InvalidToken"}"# : #"{"error":"use_dpop_nonce"}"#,
                headers: invalidToken ? [:] : ["DPoP-Nonce": "nonce"])
            let resource = OAuthTestTransport(Array(repeating: reply, count: 3))
            let xrpc = XRPCClient(auth: auth, resolver: ATProtoResolver(), transport: { try await resource.send($0) })
            do {
                let _: [String: String] = try await xrpc.authorizedGet(pdsURL, method: "test")
                Issue.record("Rejected request unexpectedly succeeded")
            } catch {}
            #expect(auth.reauthorizationRequired == invalidToken)
            #expect((auth.session == nil) == invalidToken)
            #expect(await tokens.recordedRequests().count == (invalidToken ? 1 : 0))
            #expect(await resource.recordedRequests().count == (invalidToken ? 2 : 3))
        }
    }

    @Test("an unrelated origin cannot invalidate the PDS session")
    func unrelatedOrigin() async throws {
        let keychain = OAuthTestSessionStore()
        let tokens = OAuthTestTransport([])
        let auth = ATProtoOAuthService(keychain: keychain, tokenTransport: { try await tokens.send($0) })
        defer { auth.signOut() }
        try seed(keychain)
        await auth.restoreSession()
        let resource = OAuthTestTransport([.init(status: 401, body: #"{"error":"InvalidToken"}"#)])
        let xrpc = XRPCClient(auth: auth, resolver: ATProtoResolver(), transport: { try await resource.send($0) })
        do {
            let _: [String: String] = try await xrpc.authorizedGet(URL(string: "https://other.example")!, method: "test")
            Issue.record("Rejected request unexpectedly succeeded")
        } catch {}
        #expect(auth.session != nil && !auth.reauthorizationRequired)
        #expect(await tokens.recordedRequests().isEmpty)
    }

    private func seed(_ keychain: OAuthTestSessionStore, accessToken: String = "old-access",
                      binding: String? = ATProtoOAuthConfig.clientID, expiresAt: Date = .distantFuture) throws {
        let session = AuthSession(did: "did:plc:test", pdsURL: pdsURL,
            tokenEndpoint: URL(string: "https://issuer.example/token")!, accessToken: accessToken,
            refreshToken: "old-refresh", tokenType: "DPoP", scope: ATProtoOAuthService.scopes, expiresAt: expiresAt)
        var record: [String: Any] = [
            "session": try JSONSerialization.jsonObject(with: JSONEncoder().encode(session)),
            "dpopPrivateKey": Data(repeating: 1, count: 32).base64EncodedString(),
        ]
        if let binding { record["clientID"] = binding }
        keychain.set(try JSONSerialization.data(withJSONObject: record).base64EncodedString(), for: "oauth.session.v2")
    }
}
