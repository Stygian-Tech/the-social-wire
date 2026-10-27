import Foundation

struct SocialProEntitlement: Decodable, Equatable, Sendable {
    let viewerDid: String
    let plan: Plan

    enum Plan: String, Decodable, Sendable {
        case free
        case pro
    }

    static func permitsFeatureAccess(
        featuresReleased: Bool,
        entitlementGatingEnabled: Bool,
        viewerDID: String?,
        plan: Plan?
    ) -> Bool {
        guard featuresReleased, viewerDID != nil else { return false }
        return !entitlementGatingEnabled || plan == .pro
    }
}
