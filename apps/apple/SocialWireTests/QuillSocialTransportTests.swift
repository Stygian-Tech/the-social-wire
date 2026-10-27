import Foundation
import ReadStateCore
import Testing
@testable import SocialWire

@Suite("Quill social transport")
@MainActor
struct QuillSocialTransportTests {
    @Test("Quill's profile, discovery, notification, chat, and record actions have explicit OAuth grants")
    func parityScopes() {
        let granted = Set(ATProtoOAuthService.scopes.split(separator: " ").map(String.init))
        for method in ["app.bsky.feed.getActorLikes", "app.bsky.feed.getPosts", "app.bsky.feed.getLikes",
                       "app.bsky.feed.getQuotes", "app.bsky.feed.getRepostedBy", "app.bsky.feed.searchFeedGenerators",
                       "app.bsky.unspecced.getTrends", "app.bsky.graph.getActorStarterPacks", "app.bsky.graph.getFollowers",
                       "app.bsky.labeler.getServices", "app.bsky.graph.getFollows", "app.bsky.feed.getFeedGenerator",
                       "app.bsky.actor.putPreferences"] {
            #expect(granted.contains("rpc:\(method)?aud=*"))
        }
        #expect(granted.contains("rpc:chat.bsky.convo.getConvo?aud=did:web:api.bsky.chat%23bsky_chat"))
        #expect(granted.contains("repo:community.lexicon.calendar.rsvp?action=create&action=update&action=delete"))
        #expect(granted.contains("repo:blue.flashes.story.post?action=create&action=delete"))
        #expect(granted.contains("repo:app.bsky.graph.follow?action=delete"))
        #expect(granted.contains("repo:site.standard.graph.recommend?action=create&action=delete"))
        #expect(!granted.contains(where: { $0.hasPrefix("rpc:*") || $0.hasPrefix("transition:") }))
        let flexibleAudiences = granted.filter { $0.hasPrefix("rpc:") && $0.hasSuffix("?aud=*") }
        #expect(flexibleAudiences.count == 28)
        #expect(flexibleAudiences.allSatisfy { $0.hasPrefix("rpc:app.bsky.") })
        #expect(granted.contains("rpc:chat.bsky.convo.getConvo?aud=did:web:api.bsky.chat%23bsky_chat"))
    }
    @Test("raw App View reads use the viewer PDS proxy and preserve the lexicon envelope")
    func proxiedRead() async throws {
        let auth = try await makeAuth()
        defer { auth.signOut() }
        let body = #"{"feed":[],"cursor":"next","unknown":{"preserved":true}}"#
        let transport = OAuthTestTransport([.init(status: 200, body: body)])
        let xrpc = XRPCClient(auth: auth, resolver: ATProtoResolver(), transport: { try await transport.send($0) })
        let data = try await xrpc.socialServiceGetData(method: "app.bsky.feed.getFeed",
            service: "did:web:alternate.example#bsky_appview", query: ["feed": "at://did:plc:feed/app.bsky.feed.generator/test"],
            labelers: ["did:plc:labeler-one", "did:plc:labeler-two"],
            expectedViewer: "did:plc:test")
        #expect(data == Data(body.utf8))
        let request = try #require(await transport.recordedRequests().first)
        #expect(request.url?.host == "pds.example.test")
        #expect(request.url?.path == "/xrpc/app.bsky.feed.getFeed")
        #expect(request.value(forHTTPHeaderField: "atproto-proxy") == "did:web:alternate.example#bsky_appview")
        #expect(request.value(forHTTPHeaderField: "atproto-accept-labelers") == "did:plc:labeler-one, did:plc:labeler-two")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "DPoP old-access")
        #expect(request.value(forHTTPHeaderField: "DPoP") != nil)
    }

    @Test("raw PDS procedures and blob uploads retain their bodies and content types")
    func rawWrites() async throws {
        let auth = try await makeAuth()
        defer { auth.signOut() }
        let transport = OAuthTestTransport([.init(status: 200, body: "{}"), .init(status: 200, body: "{\"blob\":{}}")])
        let xrpc = XRPCClient(auth: auth, resolver: ATProtoResolver(), transport: { try await transport.send($0) })
        let body = Data(#"{"repo":"did:plc:test","collection":"blue.flashes.story.post","record":{}}"#.utf8)
        _ = try await xrpc.socialPDSPostData(method: "com.atproto.repo.createRecord", body: body, expectedViewer: "did:plc:test")
        let photo = Data([0, 1, 2, 3])
        let uploaded = try await xrpc.socialUploadBlobData(data: photo, mimeType: "image/jpeg", expectedViewer: "did:plc:test")
        #expect(uploaded == Data("{\"blob\":{}}".utf8))
        let requests = await transport.recordedRequests()
        #expect(requests[0].httpBody == body)
        #expect(requests[0].httpMethod == "POST")
        #expect(requests[0].value(forHTTPHeaderField: "atproto-proxy") == nil)
        #expect(requests[1].httpBody == photo)
        #expect(requests[1].value(forHTTPHeaderField: "Content-Type") == "image/jpeg")
    }

    @Test("a different viewer is rejected before a signed request leaves the client")
    func wrongViewer() async throws {
        let auth = try await makeAuth()
        defer { auth.signOut() }
        let transport = OAuthTestTransport([])
        let xrpc = XRPCClient(auth: auth, resolver: ATProtoResolver(), transport: { try await transport.send($0) })
        await #expect(throws: ReadStateSyncFailure.self) {
            _ = try await xrpc.socialPDSGetData(method: "com.atproto.repo.listRecords", expectedViewer: "did:plc:other")
        }
        #expect(await transport.recordedRequests().isEmpty)
    }

    @Test("Sign Out discards an otherwise successful in-flight response")
    func signOutDuringRequest() async throws {
        let auth = try await makeAuth()
        let xrpc = XRPCClient(auth: auth, resolver: ATProtoResolver(), transport: { request in
            await auth.signOut()
            return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: nil)!)
        })
        await #expect(throws: ReadStateSyncFailure.self) {
            _ = try await xrpc.socialPDSGetData(method: "com.atproto.repo.listRecords", expectedViewer: "did:plc:test")
        }
    }

    @Test("public did:web story reads resolve the author PDS and send no viewer credentials")
    func publicWebAuthor() async throws {
        let auth = try await makeAuth()
        defer { auth.signOut() }
        let documents = OAuthTestTransport([.init(status: 200,
            body: ##"{"service":[{"id":"#atproto_pds","type":"AtprotoPersonalDataServer","serviceEndpoint":"https://author-pds.example"}]}"##)])
        let resolver = ATProtoResolver(transport: { try await documents.send($0) })
        let records = OAuthTestTransport([.init(status: 200, body: #"{"records":[]}"#)])
        let xrpc = XRPCClient(auth: auth, resolver: resolver, transport: { try await records.send($0) })
        _ = try await xrpc.socialPublicPDSGetData(repo: "did:web:author.example", method: "com.atproto.repo.listRecords",
            query: ["repo": "did:web:author.example", "collection": "blue.flashes.story.post"], expectedViewer: "did:plc:test")
        let document = try #require(await documents.recordedRequests().first)
        #expect(document.url?.absoluteString == "https://author.example/.well-known/did.json")
        let request = try #require(await records.recordedRequests().first)
        #expect(request.url?.host == "author-pds.example")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "DPoP") == nil)
    }

    @Test("Sign Out during public author discovery prevents the subsequent story request")
    func signOutDuringPublicDiscovery() async throws {
        let auth = try await makeAuth()
        let resolver = ATProtoResolver(transport: { request in
            await auth.signOut()
            let data = Data(##"{"service":[{"id":"#atproto_pds","serviceEndpoint":"https://author-pds.example"}]}"##.utf8)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
        })
        let records = OAuthTestTransport([])
        let xrpc = XRPCClient(auth: auth, resolver: resolver, transport: { try await records.send($0) })
        await #expect(throws: ReadStateSyncFailure.self) {
            _ = try await xrpc.socialPublicPDSGetData(repo: "did:web:author.example", method: "com.atproto.repo.listRecords",
                query: ["repo": "did:web:author.example"], expectedViewer: "did:plc:test")
        }
        #expect(await records.recordedRequests().isEmpty)
    }

    @Test("invalidated workspace scope fences a public response even while the viewer DID still matches")
    func invalidatedPublicWorkspace() async throws {
        let auth = try await makeAuth()
        defer { auth.signOut() }
        let documents = OAuthTestTransport([.init(status: 200,
            body: ##"{"service":[{"id":"#atproto_pds","serviceEndpoint":"https://author-pds.example"}]}"##)])
        let scope = SocialSessionScope(viewerDID: "did:plc:test", auth: auth)
        let resolver = ATProtoResolver(transport: { try await documents.send($0) })
        let scopedTransport = scope.transport { request in
            await scope.invalidate()
            return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        let xrpc = XRPCClient(auth: auth, resolver: resolver, transport: scopedTransport)
        await #expect(throws: CancellationError.self) {
            _ = try await xrpc.socialPublicPDSGetData(repo: "did:web:author.example", method: "com.atproto.repo.listRecords",
                query: ["repo": "did:web:author.example"], expectedViewer: "did:plc:test")
        }
    }

    @Test("DID document routing rejects unsupported methods and URL-like did:web values")
    func invalidPublicIdentity() {
        for did in ["did:key:abc", "did:web:", "did:web:user@example.test", "did:web:example.test/path",
                    "did:web:example.test:443", "did:web:example.test%3A443", "did:web:example.test?query"] {
            #expect(throws: (any Error).self) { try ATProtoResolver.didDocumentURL(did: did) }
        }
    }

    private func makeAuth() async throws -> ATProtoOAuthService {
        let store = OAuthTestSessionStore()
        let session = AuthSession(did: "did:plc:test", pdsURL: URL(string: "https://pds.example.test")!,
            tokenEndpoint: URL(string: "https://issuer.example/token")!, accessToken: "old-access",
            refreshToken: "refresh", tokenType: "DPoP", scope: ATProtoOAuthService.scopes, expiresAt: .distantFuture)
        let record: [String: Any] = [
            "session": try JSONSerialization.jsonObject(with: JSONEncoder().encode(session)),
            "dpopPrivateKey": Data(repeating: 1, count: 32).base64EncodedString(),
            "clientID": ATProtoOAuthConfig.clientID,
        ]
        store.set(try JSONSerialization.data(withJSONObject: record).base64EncodedString(), for: "oauth.session.v2")
        let auth = ATProtoOAuthService(keychain: store, tokenTransport: { _ in throw URLError(.notConnectedToInternet) })
        await auth.restoreSession()
        return auth
    }
}
