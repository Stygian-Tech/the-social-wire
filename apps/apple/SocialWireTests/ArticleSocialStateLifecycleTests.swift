import Foundation
import Testing
@testable import SocialWire

@Suite("Article social state lifecycle")
@MainActor
struct ArticleSocialStateLifecycleTests {
    private func fixture() async throws -> (SocialWireAppModel, ArticleSocialStateTransport) {
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
        let transport = ArticleSocialStateTransport()
        let model = SocialWireAppModel(authService: auth, xrpcTransport: { try await transport.send($0) })
        return (model, transport)
    }

    private var entry: EntryDetail {
        WireFeedItem(itemId: "story", canonicalUrl: "https://example.com/story", representativeUri: nil,
            title: "Story", summary: nil, publishedAt: "2026-10-13T12:00:00Z", thumbnailUrl: nil,
            source: WireFeedSource(name: "Example", domain: "example.com"), reasons: [], provenance: []).toEntryDetail()
    }

    @Test("A cancelled destination ignores late success and permits the next load")
    func cancelledLateSuccess() async throws {
        let (model, transport) = try await fixture()
        defer { model.signOut() }
        let entry = entry
        let task = Task { await model.loadArticleSocialState(for: entry) }
        await transport.waitForRequest()
        task.cancel()
        let lateRating = #"{"records":[{"uri":"at://did:plc:test/app.thesocialwire.wireFeedback/story","cid":"test","value":{"$type":"app.thesocialwire.wireFeedback","canonicalUrl":"https://example.com/story","value":"not_good","createdAt":"2026-10-13T12:00:00Z","updatedAt":"2026-10-13T12:00:00Z"}}]}"#
        await transport.complete(.success(lateRating))
        await task.value
        #expect(model.errorMessage == nil)
        #expect(model.wireArticleFeedbackValue(for: entry) == nil)
        #expect(!model.isArticleSocialStateLoading(for: entry))
        let replacement = Task { await model.loadArticleSocialState(for: entry) }
        await transport.waitForRequest()
        await transport.complete(.success("{\"records\":[]}"))
        await replacement.value
        #expect(await transport.requestCount == 2)
        #expect(model.errorMessage == nil)
    }

    @Test("Cancellation errors stay quiet even when the transport supplies them")
    func cancellationErrors() async throws {
        for error in [CancellationError() as Error, URLError(.cancelled) as Error] {
            let (model, transport) = try await fixture()
            let task = Task { await model.loadArticleSocialState(for: entry) }
            await transport.waitForRequest()
            await transport.complete(.failure(error))
            await task.value
            #expect(model.errorMessage == nil)
            #expect(!model.isArticleSocialStateLoading(for: entry))
            model.signOut()
        }
    }

    @Test("Genuine transport failures remain visible")
    func realFailure() async throws {
        let (model, transport) = try await fixture()
        defer { model.signOut() }
        let task = Task { await model.loadArticleSocialState(for: entry) }
        await transport.waitForRequest()
        await transport.complete(.failure(URLError(.notConnectedToInternet)))
        await task.value
        #expect(model.errorMessage?.hasPrefix("Couldn't load your Wire rating.") == true)
        #expect(!model.isArticleSocialStateLoading(for: entry))
    }

    @Test("Account departure fences a late failure without relying on task cancellation")
    func accountDeparture() async throws {
        let (model, transport) = try await fixture()
        let task = Task { await model.loadArticleSocialState(for: entry) }
        await transport.waitForRequest()
        model.signOut()
        await transport.complete(.failure(URLError(.notConnectedToInternet)))
        await task.value
        #expect(model.errorMessage == nil)
        #expect(!model.isArticleSocialStateLoading(for: entry))
        #expect(model.wireArticleFeedbackValue(for: entry) == nil)
    }
}

private actor ArticleSocialStateTransport {
    private var pending: CheckedContinuation<(Data, URLResponse), Error>?
    private var request: URLRequest?
    private(set) var requestCount = 0

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        self.request = request
        requestCount += 1
        // Deliberately non-cooperative: proves that cancelled tasks fence late results.
        return try await withCheckedThrowingContinuation { pending = $0 }
    }

    func waitForRequest() async {
        while pending == nil { await Task.yield() }
    }

    func complete(_ result: Result<String, Error>) {
        guard let pending, let request else { return }
        self.pending = nil
        switch result {
        case .success(let body):
            pending.resume(returning: (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: [:])!))
        case .failure(let error):
            pending.resume(throwing: error)
        }
    }
}
