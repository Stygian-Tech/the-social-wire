import Foundation
import Testing
@testable import SocialWire

struct SocialCoreTests {
    @Test("Thread segments enforce grapheme and byte limits")
    func threadSegmentLimits() {
        #expect(SocialThreadDraftSegment(text: "Hello").isValid)
        #expect(!SocialThreadDraftSegment(text: "   ").isValid)
        #expect(!SocialThreadDraftSegment(text: String(repeating: "a", count: 301)).isValid)
        #expect(!SocialThreadDraftSegment(text: String(repeating: "👨‍👩‍👧‍👦", count: 300)).isValid)
    }

    @Test("Social dates accept equivalent RFC 3339 forms")
    func socialDates() {
        let whole = SocialDate.parse("2026-10-14T12:30:00Z")
        let fractional = SocialDate.parse("2026-10-14T12:30:00.000Z")
        #expect(whole != nil)
        #expect(whole == fractional)
    }

    @Test("Notification identity remains stable across read changes")
    func notificationIdentity() {
        let author = SocialAuthor(did: "did:plc:alice", handle: "alice.test", displayName: "Alice", avatar: nil)
        let date = Date(timeIntervalSince1970: 100)
        var notification = SocialNotification(uri: "at://did:plc:alice/app.bsky.feed.like/a", cid: "cid", author: author, reason: "like", reasonSubject: nil, indexedAt: date, isRead: false, post: nil)
        let id = notification.id
        notification.isRead = true
        #expect(notification.id == id)
    }

    @Test("Pro entitlements remain bound to the server viewer")
    func proEntitlementDecoding() throws {
        let data = Data(#"{"viewerDid":"did:plc:alice","plan":"pro"}"#.utf8)
        let entitlement = try JSONDecoder().decode(SocialProEntitlement.self, from: data)
        #expect(entitlement.viewerDid == "did:plc:alice")
        #expect(entitlement.plan == .pro)
    }

    @Test("Only the Pro tools destination requires Pro")
    func proDestinationBoundary() {
        #expect(SocialDestination.proTools.requiresPro)
        #expect(SocialDestination.allCases.filter(\.requiresPro) == [.proTools])
    }

    @Test("The native rollout gate blocks Pro plans and disabled entitlement enforcement")
    func unreleasedProAccess() {
        for gating in [false, true] {
            for plan: SocialProEntitlement.Plan? in [nil, .free, .pro] {
                #expect(!SocialProEntitlement.permitsFeatureAccess(
                    featuresReleased: false, entitlementGatingEnabled: gating,
                    viewerDID: "did:plc:alice", plan: plan
                ))
            }
        }
    }

    @Test("Future released Pro features still enforce viewer and entitlement boundaries")
    func releasedProAccess() {
        #expect(SocialProEntitlement.permitsFeatureAccess(
            featuresReleased: true, entitlementGatingEnabled: true,
            viewerDID: "did:plc:alice", plan: .pro
        ))
        for plan: SocialProEntitlement.Plan? in [nil, .free] {
            #expect(!SocialProEntitlement.permitsFeatureAccess(
                featuresReleased: true, entitlementGatingEnabled: true,
                viewerDID: "did:plc:alice", plan: plan
            ))
        }
        #expect(SocialProEntitlement.permitsFeatureAccess(
            featuresReleased: true, entitlementGatingEnabled: false,
            viewerDID: "did:plc:alice", plan: .free
        ))
        for gating in [false, true] {
            #expect(!SocialProEntitlement.permitsFeatureAccess(
                featuresReleased: true, entitlementGatingEnabled: gating,
                viewerDID: nil, plan: .pro
            ))
        }
    }

    @MainActor
    @Test("Unreleased Pro refresh does not synthesize access for signed-in viewers")
    func unreleasedProModel() async {
        let model = SocialProEntitlementModel(gateway: SocialWireGatewayClient(auth: ATProtoOAuthService()))
        model.bind(viewerDID: "did:plc:alice")
        await model.refresh()
        #expect(!model.isPro)
        #expect(model.plan == nil)
        #expect(!model.isLoading)
        #expect(model.error == nil)
    }
}
