import Foundation
import Testing
@testable import SocialWire

@Suite("News shell routing")
@MainActor
struct NewsSceneModelTests {
    private func wireFixture(replies: [OAuthTestTransport.Reply], delay: Duration = .zero) async throws -> (SocialWireAppModel, OAuthTestTransport) {
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
        let transport = OAuthTestTransport(replies, delay: delay)
        let model = SocialWireAppModel(authService: auth, gatewayTransport: { try await transport.send($0) })
        model.wireCatalog = WireFeedCatalog(enabled: true, available: true, title: "The Wire", subtitle: "", supportedLanguages: ["en"], latestGenerationId: nil, generatedAt: nil)
        return (model, transport)
    }

    @Test("Selecting Wire schedules no detached feed load before the destination task")
    func wireSelectionDoesNotSpawnRequest() async throws {
        let (model, transport) = try await wireFixture(replies: [])
        defer { model.authService.signOut() }
        model.selectReaderListSource(.wire)
        try await Task.sleep(for: .milliseconds(10))
        #expect(model.readerListSource == .wire)
        #expect(!model.isLoadingEntries)
        #expect(await transport.recordedRequests().isEmpty)
    }

    @Test("Cancelled Wire destination permits a new load while its old response is pending")
    func cancelledWireLoadDoesNotSuppressReplacement() async throws {
        let edition = WireEditionPage(editionVersion: "1", generationId: "new-generation",
            generatedAt: "2026-10-12T12:00:00Z", language: "en", source: .ranked, degraded: false,
            stories: [], topStoryIds: [], publicationSpotlights: [], storyRails: [], people: [], trendingStoryIds: [], moreCursor: nil)
        let reply = OAuthTestTransport.Reply(status: 200, body: String(decoding: try JSONEncoder().encode(edition), as: UTF8.self))
        let (model, transport) = try await wireFixture(replies: [reply, reply], delay: .milliseconds(30))
        defer { model.authService.signOut() }
        model.selectReaderListSource(.wire)
        let obsolete = Task { await model.loadWireEdition() }
        while await transport.recordedRequests().isEmpty { await Task.yield() }
        obsolete.cancel()
        while model.isLoadingEntries { await Task.yield() }
        await model.loadWireEdition()
        await obsolete.value
        #expect(await transport.recordedRequests().count == 2)
        #expect(model.wireEdition?.generationId == "new-generation")
        #expect(!model.isLoadingEntries)
    }

    @Test("Tabs keep their editorial order while gated destinations are omitted")
    func availableTabOrder() {
        #expect(NewsTab.available(wire: true, circle: true, finance: true, sports: true, podcasts: true) == NewsTab.allCases)
        #expect(
            NewsTab.available(wire: false, circle: false)
                == [.library, .saved, .search]
        )
    }

    @Test("Circle stays reachable while its catalog loads or lacks stories")
    func circleNavigationDoesNotRequireAvailableStories() {
        for available in [false, true] {
            let catalog = CircleFeedCatalog(
                enabled: true, available: available, title: "Your Circle", subtitle: "",
                supportedLanguages: ["en"], latestGenerationId: nil, generatedAt: nil
            )
            #expect(NewsTab.available(
                preferences: .defaults, wireCatalog: nil, circleCatalog: catalog
            ).contains(.circle))
        }
        #expect(NewsTab.available(
            preferences: .defaults, wireCatalog: nil, circleCatalog: nil
        ).contains(.circle))
    }

    @Test("Explicit Circle hide and global disable still remove its destination")
    func circleNavigationHonorsVisibilityControls() {
        let disabled = CircleFeedCatalog(
            enabled: false, available: true, title: "Your Circle", subtitle: "",
            supportedLanguages: ["en"], latestGenerationId: nil, generatedAt: nil
        )
        #expect(!NewsTab.available(
            preferences: .defaults, wireCatalog: nil, circleCatalog: disabled
        ).contains(.circle))
        var preferences = ReaderFeedPreferences.defaults
        preferences.showCircle = false
        #expect(!NewsTab.available(
            preferences: preferences, wireCatalog: nil, circleCatalog: nil
        ).contains(.circle))
    }

    @Test("Primary slots stay stable while catalogs load and honor resolved gates")
    func primarySlotsRespectCatalogAvailability() {
        let model = SocialWireAppModel()
        model.loadPrimaryTabPreferences()
        #expect(model.primaryTabFeeds.contains(.wire))
        #expect(model.primaryTabFeeds.contains(.circle))

        model.wireCatalog = WireFeedCatalog(
            enabled: true, available: true, title: "The Wire", subtitle: "",
            supportedLanguages: ["en"], latestGenerationId: "g1", generatedAt: nil
        )
        model.circleCatalog = CircleFeedCatalog(
            enabled: false, available: true, title: "Your Circle", subtitle: "",
            supportedLanguages: ["en"], latestGenerationId: nil, generatedAt: nil
        )
        model.loadPrimaryTabPreferences()
        #expect(model.primaryTabFeeds.contains(.wire))
        #expect(!model.primaryTabFeeds.contains(.circle))

        model.circleCatalog = CircleFeedCatalog(
            enabled: true, available: false, title: "Your Circle", subtitle: "",
            supportedLanguages: ["en"], latestGenerationId: nil, generatedAt: nil
        )
        model.feedPreferences.showWire = false
        model.loadPrimaryTabPreferences()
        #expect(!model.primaryTabFeeds.contains(.wire))
        #expect(model.primaryTabFeeds.contains(.circle))
    }

    @Test("Podcast navigation honors section visibility while preserving other destinations")
    func podcastNavigationHonorsVisibility() {
        var preferences = ReaderFeedPreferences.defaults
        let visible = NewsTab.available(
            preferences: preferences, wireCatalog: nil, circleCatalog: nil,
            podcastsAvailable: true
        )
        #expect(visible.contains(.podcasts))
        preferences.showPodcasts = false
        let hidden = NewsTab.available(
            preferences: preferences, wireCatalog: nil, circleCatalog: nil,
            podcastsAvailable: true
        )
        #expect(hidden == visible.filter { $0 != .podcasts })

        let suiteName = "NewsSceneModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let scene = NewsSceneModel(defaults: defaults)
        scene.updateContext(viewerDID: "did:plc:viewer", availableTabs: visible)
        scene.select(.podcasts, availableTabs: visible)
        scene.navigate(to: .settings, in: .podcasts)
        scene.updateContext(viewerDID: "did:plc:viewer", availableTabs: hidden)
        #expect(scene.selectedTab == .wire)
        #expect(scene.activeRoute == .settings)
    }

    @Test("Other feed settings preserve hidden Social and Podcast sections")
    func unrelatedFeedSettingsPreserveSectionVisibility() async {
        let model = SocialWireAppModel()
        model.feedPreferences.showSocial = false
        model.feedPreferences.showPodcasts = false

        await model.setFeedDisplayOption(.showFeedOnly, for: .subscribed)
        #expect(!model.feedPreferences.showSocial && !model.feedPreferences.showPodcasts)
        await model.setFeedVisible(.following, visible: false)
        #expect(!model.feedPreferences.showSocial && !model.feedPreferences.showPodcasts)
        await model.setFeedUnreadCountVisible(.subscribed, visible: true)
        #expect(!model.feedPreferences.showSocial && !model.feedPreferences.showPodcasts)
    }

    @Test("Last tab is restored per viewer")
    func restoresSelectedTabPerViewer() {
        let suiteName = "NewsSceneModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = NewsSceneModel(defaults: defaults)
        first.updateContext(
            viewerDID: "did:plc:alice",
            availableTabs: [.wire, .library, .saved, .search]
        )
        first.select(.saved, availableTabs: [.wire, .library, .saved, .search])

        let restored = NewsSceneModel(defaults: defaults)
        restored.updateContext(
            viewerDID: "did:plc:alice",
            availableTabs: [.wire, .library, .saved, .search]
        )
        #expect(restored.selectedTab == .saved)

        restored.updateContext(
            viewerDID: "did:plc:bob",
            availableTabs: [.wire, .library, .saved, .search]
        )
        #expect(restored.selectedTab == .wire)
    }

    @Test("A temporarily unavailable preferred feed is restored when its catalog arrives")
    func restoresPreferredGatedTab() {
        let suiteName = "NewsSceneModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            NewsTab.wire.rawValue,
            forKey: NewsSceneModel.storageKey(viewerDID: "did:plc:alice")
        )

        let model = NewsSceneModel(defaults: defaults)
        model.updateContext(
            viewerDID: "did:plc:alice",
            availableTabs: [.library, .saved, .search]
        )
        #expect(model.selectedTab == .library)

        model.updateContext(
            viewerDID: "did:plc:alice",
            availableTabs: [.wire, .library, .saved, .search]
        )
        #expect(model.selectedTab == .wire)
    }

    @Test("Each tab owns an independent route path")
    func independentPaths() {
        let model = NewsSceneModel()
        model.navigate(to: .entry(id: "wire-story"), in: .wire)
        model.navigate(to: .savedLink(id: "saved-story"), in: .saved)

        #expect(model.path(for: .wire) == [.entry(id: "wire-story")])
        #expect(model.path(for: .saved) == [.savedLink(id: "saved-story")])
        #expect(model.path(for: .library).isEmpty)
    }

    @Test("Active route follows the selected tab without destroying other tab paths")
    func activeRouteFollowsSelectedTab() {
        let model = NewsSceneModel()
        model.navigate(to: .entry(id: "wire-story"), in: .wire)
        model.navigate(to: .savedLink(id: "saved-story"), in: .saved)

        model.select(.wire, availableTabs: NewsTab.allCases)
        #expect(model.activeRoute == .entry(id: "wire-story"))

        model.select(.saved, availableTabs: NewsTab.allCases)
        #expect(model.activeRoute == .savedLink(id: "saved-story"))

        model.resetPath(for: .saved)
        #expect(model.activeRoute == nil)
        #expect(model.path(for: .wire) == [.entry(id: "wire-story")])
    }

    @Test("Switching Read Later and Archive returns to the list and persists the cleared route",
          arguments: [ReaderListSource.readLater, .archive])
    func savedSourceSwitchClearsUnavailableDetail(destination: ReaderListSource) {
        let suiteName = "NewsSavedSourceSwitchTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = NewsSceneModel(defaults: defaults)
        model.updateContext(viewerDID: "did:plc:alice", availableTabs: NewsTab.allCases)
        model.navigate(to: .savedLink(id: "previous-source-story"), in: .saved)
        model.navigate(to: .entry(id: "wire-story"), in: .wire)

        model.prepareForReaderSourceChange(
            from: destination == .archive ? .readLater : .archive, to: destination
        )
        model.select(.saved, availableTabs: NewsTab.allCases)

        #expect(model.activeRoute == nil)
        #expect(model.path(for: .wire) == [.entry(id: "wire-story")])
        let restored = NewsSceneModel(defaults: defaults)
        restored.updateContext(viewerDID: "did:plc:alice", availableTabs: NewsTab.allCases)
        #expect(restored.path(for: .saved).isEmpty)
    }

    @Test("Switching Subscribed and Following clears the previous feed detail",
          arguments: [ReaderListSource.subscribed, .following])
    func librarySourceSwitchClearsUnavailableDetail(destination: ReaderListSource) {
        let model = NewsSceneModel()
        model.navigate(to: .publication(id: "previous-publication"), in: .library)
        model.navigate(to: .entry(id: "previous-source-story"), in: .library)
        model.navigate(to: .savedLink(id: "saved-story"), in: .saved)

        model.prepareForReaderSourceChange(
            from: destination == .following ? .subscribed : .following, to: destination
        )
        model.select(.library, availableTabs: NewsTab.allCases)

        #expect(model.activeRoute == nil)
        #expect(model.path(for: .saved) == [.savedLink(id: "saved-story")])
    }

    @Test("Re-selecting the current source preserves its open article")
    func unchangedReaderSourcePreservesDetail() {
        let model = NewsSceneModel()
        model.navigate(to: .entry(id: "current-story"), in: .library)
        model.prepareForReaderSourceChange(from: .subscribed, to: .subscribed)
        #expect(model.path(for: .library) == [.entry(id: "current-story")])
    }

    @Test("Hiding the active discovery feed selects a visible tab and keeps Settings open")
    func hiddenFeedPreservesSettings() {
        let suiteName = "NewsSceneModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for tab in [NewsTab.wire, .circle] {
            let model = NewsSceneModel(defaults: defaults)
            model.updateContext(viewerDID: "did:plc:alice", availableTabs: NewsTab.allCases)
            model.select(tab, availableTabs: NewsTab.allCases)
            model.navigate(to: .profile, in: tab)
            model.navigate(to: .settings, in: tab)

            model.updateContext(
                viewerDID: "did:plc:alice",
                availableTabs: [.library, .saved, .search]
            )
            #expect(model.selectedTab == .library)
            #expect(model.path(for: .library).last == .settings)
            #expect(model.path(for: tab) == [.profile, .settings])
        }
    }

    @Test("Routes restore independently for each viewer and window")
    func restoresRoutesPerViewerAndWindow() {
        let suiteName = "NewsSceneModelRouteTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = NewsSceneModel(defaults: defaults, windowID: "window-a")
        first.updateContext(
            viewerDID: "did:plc:alice",
            availableTabs: [.wire, .library, .saved, .search]
        )
        first.setPath(
            [.publication(id: "at://alice/site.standard.publication/main")],
            for: .library
        )

        let restored = NewsSceneModel(defaults: defaults, windowID: "window-a")
        restored.updateContext(
            viewerDID: "did:plc:alice",
            availableTabs: [.wire, .library, .saved, .search]
        )
        #expect(
            restored.path(for: .library)
                == [.publication(id: "at://alice/site.standard.publication/main")]
        )

        let otherWindow = NewsSceneModel(defaults: defaults, windowID: "window-b")
        otherWindow.updateContext(
            viewerDID: "did:plc:alice",
            availableTabs: [.wire, .library, .saved, .search]
        )
        #expect(otherWindow.path(for: .library).isEmpty)

        restored.updateContext(
            viewerDID: "did:plc:bob",
            availableTabs: [.wire, .library, .saved, .search]
        )
        #expect(restored.path(for: .library).isEmpty)
    }
}
