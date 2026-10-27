import Foundation
import Testing
@testable import SocialWire

struct SocialCoreTests {
    @Test("Pro entitlements remain bound to the server viewer")
    func proEntitlementDecoding() throws {
        let data = Data(#"{"viewerDid":"did:plc:alice","plan":"pro"}"#.utf8)
        let entitlement = try JSONDecoder().decode(SocialProEntitlement.self, from: data)
        #expect(entitlement.viewerDid == "did:plc:alice")
        #expect(entitlement.plan == .pro)
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

}
