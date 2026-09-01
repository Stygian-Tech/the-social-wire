import Foundation
import Testing
@testable import SocialWire

@Suite("News shell routing")
@MainActor
struct NewsSceneModelTests {
    @Test("Tabs keep their editorial order while gated destinations are omitted")
    func availableTabOrder() {
        #expect(NewsTab.available(wire: true, circle: true) == NewsTab.allCases)
        #expect(
            NewsTab.available(wire: false, circle: false)
                == [.library, .saved, .search]
        )
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
