import Foundation
import Testing
@testable import SocialWire

@Suite("Scene-owned social navigation")
@MainActor
struct SocialNavigationStateTests {
    @Test("Returning to a workspace restores each destination's independent history")
    func workspaceReconstruction() {
        let navigation = SocialNavigationState()
        navigation.bind(viewerDID: "did:plc:alice")
        let thread = SocialRoute.post(uri: "at://did:plc:alice/app.bsky.feed.post/thread")
        let profile = SocialRoute.profile(did: "did:plc:author")
        navigation.setPath([thread], for: .timeline, contextID: navigation.contextID)
        navigation.setPath([profile], for: .explore, contextID: navigation.contextID)

        // Rebinding on reappearance must not erase a scene's existing histories.
        navigation.bind(viewerDID: "did:plc:alice")
        #expect(navigation.path(for: .timeline) == [thread])
        #expect(navigation.path(for: .explore) == [profile])
        #expect(navigation.path(for: .notifications).isEmpty)
        let otherScene = SocialNavigationState()
        otherScene.bind(viewerDID: "did:plc:alice")
        #expect(otherScene.path(for: .timeline).isEmpty)
    }

    @Test("Avatar shortcuts open the current viewer profile without changing other histories")
    func avatarProfileShortcut() {
        let navigation = SocialNavigationState()
        navigation.bind(viewerDID: "did:plc:alice")
        let notifications = SocialRoute.post(uri: "at://did:plc:alice/app.bsky.feed.post/notification")
        navigation.setPath([notifications], for: .notifications, contextID: navigation.contextID)
        navigation.showProfile(viewerDID: "did:plc:alice")
        #expect(navigation.path(for: .timeline) == [.profile(did: "did:plc:alice")])
        #expect(navigation.path(for: .notifications) == [notifications])
        navigation.showProfile(viewerDID: "did:plc:bob")
        #expect(navigation.path(for: .timeline) == [.profile(did: "did:plc:bob")])
        #expect(navigation.path(for: .notifications).isEmpty)
    }

    @Test("The Social tab returns Home without clearing other destination histories")
    func homeShortcut() {
        let navigation = SocialNavigationState()
        navigation.bind(viewerDID: "did:plc:alice")
        let route = SocialRoute.profile(did: "did:plc:alice")
        navigation.setPath([route], for: .timeline, contextID: navigation.contextID)
        navigation.setPath([route], for: .notifications, contextID: navigation.contextID)
        navigation.showHome()
        #expect(navigation.path(for: .timeline).isEmpty)
        #expect(navigation.path(for: .notifications) == [route])
    }

    @Test("Account changes clear all destinations and reject stale stack setters")
    func accountChange() {
        let navigation = SocialNavigationState()
        navigation.bind(viewerDID: "did:plc:alice")
        let aliceContext = navigation.contextID
        let route = SocialRoute.profile(did: "did:plc:private-profile")
        for destination in SocialDestination.allCases {
            navigation.setPath([route], for: destination, contextID: aliceContext)
        }
        navigation.bind(viewerDID: "did:plc:bob")
        navigation.setPath([route], for: .timeline, contextID: aliceContext)
        #expect(navigation.contextID != aliceContext)
        for destination in SocialDestination.allCases {
            #expect(navigation.path(for: destination).isEmpty)
        }
    }

    @Test("Signing out and returning as the same viewer starts a new route context")
    func sameViewerReentry() {
        let navigation = SocialNavigationState()
        navigation.bind(viewerDID: "did:plc:alice")
        let previousContext = navigation.contextID
        let route = SocialRoute.post(uri: "at://did:plc:alice/app.bsky.feed.post/private")
        navigation.setPath([route], for: .bookmarks, contextID: previousContext)
        navigation.bind(viewerDID: nil)
        navigation.bind(viewerDID: "did:plc:alice")
        navigation.setPath([route], for: .bookmarks, contextID: previousContext)
        #expect(navigation.path(for: .bookmarks).isEmpty)
        #expect(navigation.contextID != previousContext)
    }
}
