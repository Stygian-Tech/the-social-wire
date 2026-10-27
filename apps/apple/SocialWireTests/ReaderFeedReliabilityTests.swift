import Foundation
import SwiftData
import Testing
@testable import SocialWire

@Suite("Reader feed request ownership", .serialized)
@MainActor
struct ReaderFeedReliabilityTests {
    private func fixture(gatewayURLSession: URLSession = .shared) async throws -> (SocialWireAppModel, ReaderFeedPendingTransport) {
        let store = OAuthTestSessionStore()
        let tokens = OAuthTestTransport([.init(status: 200, body: #"{"access_token":"rotated-access","refresh_token":"rotated-refresh","token_type":"DPoP","expires_in":3600}"#)])
        let auth = ATProtoOAuthService(keychain: store, tokenTransport: { try await tokens.send($0) })
        let session = AuthSession(did: "did:plc:reader-\(UUID().uuidString)", pdsURL: URL(string: "https://pds.example.test")!,
            tokenEndpoint: URL(string: "https://issuer.example/token")!, accessToken: "access",
            refreshToken: "refresh", tokenType: "DPoP", scope: ATProtoOAuthService.scopes, expiresAt: .distantFuture)
        let record: [String: Any] = [
            "session": try JSONSerialization.jsonObject(with: JSONEncoder().encode(session)),
            "dpopPrivateKey": Data(repeating: 1, count: 32).base64EncodedString(),
            "clientID": ATProtoOAuthConfig.clientID,
        ]
        store.set(try JSONSerialization.data(withJSONObject: record).base64EncodedString(), for: "oauth.session.v2")
        await auth.restoreSession()
        let transport = ReaderFeedPendingTransport()
        let model = SocialWireAppModel(authService: auth, gatewayTransport: { try await transport.send($0) },
            gatewayURLSession: gatewayURLSession, initialReaderListSource: .subscribed)
        model.feedSelection = .topLevel(.subscribed)
        model.readerFilter = .all
        return (model, transport)
    }

    private func page(_ id: String, cursor: String? = nil) throws -> String {
        String(decoding: try JSONEncoder().encode(AppViewEntryListResponse(entries: [item(id)], cursor: cursor)), as: UTF8.self)
    }

    private func item(_ id: String) -> EntryListItem {
        EntryListItem(entryId: id, title: id, summary: nil, publishedAt: "2026-10-26T00:00:00Z", thumbnailUrl: nil, thumbnailFallbackUrl: nil)
    }

    private func publication(_ id: String) -> DiscoveredPublication {
        DiscoveredPublication(publicationId: id, authorDid: "did:web:example.test", authorHandle: "example.test",
            title: id, discoveredAt: "2026-10-26T00:00:00Z")
    }

    private func applySidebar(_ model: SocialWireAppModel) throws {
        let rows = ["publication-a", "publication-b"].map { id in
            SidebarPublicationRowDTO(publicationId: id, subscriptionPublicationId: nil,
                authorDid: "did:web:example.test", authorHandle: "example.test", title: id,
                iconUrl: nil, avatarUrl: nil, discoveredAt: "2026-10-26T00:00:00Z",
                appViewScope: PublicationAppViewScopeDTO(authorDid: "did:web:example.test", publicationAtUri: nil,
                    publicationScopeAtUris: [], publicationSiteUrls: []), unreadCount: 0)
        }
        let projection = PublicationSidebarResponseDTO(viewerDid: model.viewerDID!, folders: nil, publicationPrefs: nil,
            folderSections: nil, allPublicationRows: rows, myPublications: [], subscribedUnfoldered: rows,
            followingTabPublications: [], enrollAuthorDids: [], refreshedAt: "2026-10-26T00:00:00Z", unreadCountsByPublicationId: nil)
        let body = try JSONEncoder().encode(projection)
        let encoded = String(decoding: body, as: UTF8.self)
        let event = try #require(BootstrapStreamNDJSON.parseLines("{\"kind\":\"sidebarPriority\",\"sidebarPriority\":\(encoded)}").first)
        model.applyBootstrapStreamEvent(event)
    }

    @Test("An older aggregate response cannot replace a later destination or its cursor")
    func aggregateDestinationRace() async throws {
        let (model, transport) = try await fixture()
        defer { model.signOut() }
        let first = Task { await model.selectFolderFeed(folderRkey: "a") }
        await transport.waitForRequests(1)
        let second = Task { await model.selectFolderFeed(folderRkey: "b") }
        await transport.waitForRequests(2)
        await transport.complete(1, body: try page("b", cursor: "b-next"))
        await second.value
        await transport.complete(0, body: try page("a", cursor: "a-next"))
        await first.value
        #expect(model.feedSelection == .folder("b"))
        #expect(model.entries.map(\.entryId) == ["b"])
        #expect(model.canLoadMoreEntries)
        #expect(!model.isLoadingEntries)
    }

    @Test("Returning to the same scope does not revive an earlier request")
    func aggregateABARace() async throws {
        let (model, transport) = try await fixture()
        defer { model.signOut() }
        let first = Task { await model.selectFolderFeed(folderRkey: "a") }
        await transport.waitForRequests(1)
        let middle = Task { await model.selectFolderFeed(folderRkey: "b") }
        await transport.waitForRequests(2)
        let last = Task { await model.selectFolderFeed(folderRkey: "a") }
        await transport.waitForRequests(3)
        await transport.complete(0, body: try page("obsolete-a"))
        await first.value
        #expect(model.isLoadingEntries)
        #expect(model.entries.isEmpty)
        await transport.complete(2, body: try page("current-a"))
        await last.value
        await transport.complete(1, body: "{}", status: 404)
        await middle.value
        #expect(model.entries.map(\.entryId) == ["current-a"])
        #expect(model.errorMessage == nil)
    }

    @Test("Changing the reader filter rejects the old response and old loading completion")
    func filterRace() async throws {
        let (model, transport) = try await fixture()
        defer { model.signOut() }
        let initial = Task { await model.selectFolderFeed(folderRkey: "a") }
        await transport.waitForRequests(1)
        let filtered = Task { await model.applyReaderFilter(.unread) }
        await transport.waitForRequests(2)
        await transport.complete(0, body: try page("all-only"))
        await initial.value
        #expect(model.isLoadingEntries)
        #expect(model.entries.isEmpty)
        await transport.complete(1, body: try page("unread"))
        await filtered.value
        #expect(model.entries.map(\.entryId) == ["unread"])
    }

    @Test("Late aggregate pagination cannot append rows to a different destination")
    func paginationRace() async throws {
        let (model, transport) = try await fixture()
        defer { model.signOut() }
        let initial = Task { await model.selectFolderFeed(folderRkey: "a") }
        await transport.waitForRequests(1)
        await transport.complete(0, body: try page("a-first", cursor: "a-next"))
        await initial.value
        let more = Task { await model.loadMoreSelectedFeedIfNeeded(triggeredByEntryId: "a-first") }
        await transport.waitForRequests(2)
        let other = Task { await model.selectFolderFeed(folderRkey: "b") }
        await transport.waitForRequests(3)
        await transport.complete(2, body: try page("b"))
        await other.value
        await transport.complete(1, body: try page("a-second", cursor: "a-third"))
        await more.value
        #expect(model.entries.map(\.entryId) == ["b"])
        #expect(!model.canLoadMoreEntries)
        #expect(!model.isLoadingMoreEntries)
    }

    @Test("Publication responses cannot replace a later aggregate selection")
    func publicationRace() async throws {
        let (model, transport) = try await fixture()
        defer { model.signOut() }
        try applySidebar(model)
        model.entries = [item("previous-aggregate")]
        let first = Task { await model.selectPublication(publication("publication-a")) }
        await transport.waitForRequests(1)
        #expect(model.entries.isEmpty)
        let second = Task { await model.selectFolderFeed(folderRkey: "b") }
        await transport.waitForRequests(2)
        await transport.complete(1, body: try page("b"))
        await second.value
        await transport.complete(0, body: try page("publication-a-old"))
        await first.value
        #expect(model.selectedPublication == nil)
        #expect(model.entries.map(\.entryId) == ["b"])
    }

    @Test("Background publication refresh cannot contaminate a newer publication")
    func backgroundPublicationRace() async throws {
        let (model, transport) = try await fixture()
        defer { model.signOut() }
        try applySidebar(model)
        model.feedSelection = .publication("publication-a")
        model.selectedPublication = publication("publication-a")
        model.entries = [item("a")]
        let old = Task { await model.refreshActivePublicationFeedIfNeeded() }
        await transport.waitForRequests(1)
        let current = Task { await model.selectPublication(publication("publication-b")) }
        await transport.waitForRequests(2)
        await transport.complete(1, body: try page("b"))
        await current.value
        await transport.complete(0, body: try page("a-old"))
        await old.value
        #expect(model.entries.map(\.entryId) == ["b"])
    }

    @Test("Signing out rejects an in-flight response")
    func accountDeparture() async throws {
        let (model, transport) = try await fixture()
        let loading = Task { await model.selectFolderFeed(folderRkey: "a") }
        await transport.waitForRequests(1)
        model.signOut()
        await transport.complete(0, body: try page("private-old-account"))
        await loading.value
        #expect(model.entries.isEmpty)
        #expect(!model.isLoadingEntries)
        #expect(model.errorMessage == nil)
    }

    @Test("First-unread bootstrap pages never navigate an aggregate, saved, or Wire destination")
    func passiveBootstrapNeverNavigates() async throws {
        let (model, _) = try await fixture()
        defer { model.signOut() }
        try applySidebar(model)
        let selections: [FeedSelection] = [.folder("a"), .topLevel(.subscribed), .topLevel(.wire), .topLevel(.readLater)]
        for selection in selections {
            model.feedSelection = selection
            model.selectedPublication = nil
            model.entries = [item("current")]
            let selected = try #require(BootstrapStreamNDJSON.parseLines(#"{"kind":"selectedPublication","selectedPublication":{"publicationId":"publication-a"}}"#).first)
            let page = try #require(BootstrapStreamNDJSON.parseLines(#"{"kind":"entriesPage","entriesPage":{"publicationId":"publication-a","entries":[],"source":"live_projection"}}"#).first)
            model.applyBootstrapStreamEvent(selected)
            model.applyBootstrapStreamEvent(page)
            await model.applyPendingStreamedBootstrapSelectionIfNeeded()
            #expect(model.feedSelection == selection)
            #expect(model.selectedPublication == nil)
            #expect(model.entries.map(\.entryId) == ["current"])
        }
    }

    @Test("A historical publication cache cannot replace the authoritative aggregate selection")
    func cacheRestorePreservesScope() async throws {
        let (model, _) = try await fixture()
        defer { model.signOut() }
        let key = "the-social-wire.last-selected-publication-id"
        let previous = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        UserDefaults.standard.set("publication-a", forKey: key)
        let container = try ReaderSwiftDataStack.inMemoryTestContainer()
        let context = ModelContext(container)
        try ReaderCacheCoordinator(modelContext: context).upsertPublicationEntries(publicationId: "publication-a", entries: [item("historical")])
        model.entries = [item("aggregate")]
        model.configureReaderPersistence(modelContext: context)
        #expect(model.feedSelection == .topLevel(.subscribed))
        #expect(model.selectedPublication == nil)
        #expect(model.entries.map(\.entryId) == ["aggregate"])
    }
    @Test("A delayed bootstrap cannot restore the scope captured before explicit navigation")
    func bootstrapRestorationRace() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReaderBootstrapURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (model, transport) = try await fixture(gatewayURLSession: session)
        defer { model.signOut() }
        FeedSelectionStorage.save(.topLevel(.subscribed), viewerDid: model.viewerDID!)
        let bootstrap = Task { await model.refreshSidebarProjection() }
        await ReaderBootstrapURLProtocol.requests.waitForRequest()
        let navigation = Task { await model.selectFolderFeed(folderRkey: "user-choice") }
        await transport.waitForRequests(1)
        await transport.complete(0, body: try page("chosen-folder"))
        await navigation.value
        await ReaderBootstrapURLProtocol.requests.completeNext(body: #"{"kind":"done","done":{"refreshedAt":"2026-10-26T00:00:00Z"}}"# + "\n")
        await bootstrap.value
        model.stopProactiveFeedRefreshLoop()
        #expect(model.feedSelection == .folder("user-choice"))
        #expect(model.entries.map(\.entryId) == ["chosen-folder"])
    }

    @Test("Repeated sidebar refresh preserves an existing top-level feed and its open article")
    func sidebarRefreshDoesNotBlankSameScope() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReaderBootstrapURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (model, _) = try await fixture(gatewayURLSession: session)
        defer { model.signOut() }
        FeedSelectionStorage.save(.topLevel(.subscribed), viewerDid: model.viewerDID!)
        model.entries = [item("already-visible")]
        model.selectedEntry = EntryDetail(entryId: "already-visible", title: "Visible", publishedAt: "2026-10-26T00:00:00Z",
            contentHtml: "<p>Article</p>", originalUrl: nil, embedUrl: nil, bskyPostUri: nil, bskyPostCid: nil)
        for _ in 0..<2 {
            let refresh = Task { await model.refreshSidebarProjection() }
            await ReaderBootstrapURLProtocol.requests.completeNext(body: #"{"kind":"done","done":{"refreshedAt":"2026-10-26T00:00:00Z"}}"# + "\n")
            await refresh.value
            model.stopProactiveFeedRefreshLoop()
            #expect(model.entries.map(\.entryId) == ["already-visible"])
            #expect(model.feedSelection == .topLevel(.subscribed))
            #expect(model.selectedEntry?.entryId == "already-visible")
        }
    }

    @Test("Bootstrap callbacks finish applying before consumeBootstrapStream returns")
    func bootstrapCallbacksAreSequential() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReaderBootstrapURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (model, _) = try await fixture(gatewayURLSession: session)
        defer { model.signOut() }
        let gateway = SocialWireGatewayClient(auth: model.authService, urlSession: session)
        let recorder = ReaderBootstrapEventRecorder()
        let consuming = Task {
            try await gateway.consumeBootstrapStream { event in
                await recorder.appendAfterYield(event.kind)
            }
        }
        await ReaderBootstrapURLProtocol.requests.completeNext(body: """
        {"kind":"warning","warning":{"message":"first"}}
        {"kind":"done","done":{"refreshedAt":"2026-10-26T00:00:00Z"}}

        """)
        try await consuming.value
        #expect(await recorder.kinds == [.warning, .done])
    }

    @Test("Same-account token rotation does not discard an in-flight feed response")
    func sameAccountTokenRefresh() async throws {
        let (model, transport) = try await fixture()
        defer { model.signOut() }
        let loading = Task { await model.selectFolderFeed(folderRkey: "a") }
        await transport.waitForRequests(1)
        let rejected = try #require(model.authService.session)
        let renewed = try await model.authService.refreshedSession(rejected: rejected)
        #expect(renewed.accessToken != rejected.accessToken)
        await transport.complete(0, body: try page("current-account"))
        await loading.value
        #expect(model.entries.map(\.entryId) == ["current-account"])
        #expect(!model.isLoadingEntries)
    }

    @Test("Refreshing the same publication keeps its visible rows while the response is pending")
    func samePublicationRefreshPreservesContent() async throws {
        let (model, transport) = try await fixture()
        defer { model.signOut() }
        try applySidebar(model)
        model.feedSelection = .publication("publication-a")
        model.selectedPublication = publication("publication-a")
        model.entries = [item("visible")]
        let refreshing = Task { await model.refreshPublication(publication("publication-a")) }
        await transport.waitForRequests(1)
        #expect(model.entries.map(\.entryId) == ["visible"])
        await transport.complete(0, body: try page("refreshed"))
        await refreshing.value
        #expect(model.entries.map(\.entryId) == ["refreshed"])
    }

}
