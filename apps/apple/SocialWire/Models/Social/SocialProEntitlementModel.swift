import Foundation
import Observation

@MainActor
@Observable
final class SocialProEntitlementModel {
    private let gateway: SocialWireGatewayClient
    private(set) var viewerDID: String?
    private(set) var plan: SocialProEntitlement.Plan?
    private(set) var isLoading = false
    private(set) var error: String?

    var isPro: Bool {
        SocialProEntitlement.permitsFeatureAccess(
            featuresReleased: SocialWireAPIEnvironment.proFeaturesReleased,
            entitlementGatingEnabled: SocialWireAPIEnvironment.proGatingEnabled,
            viewerDID: viewerDID,
            plan: plan
        )
    }

    init(gateway: SocialWireGatewayClient) {
        self.gateway = gateway
    }

    func bind(viewerDID: String?) {
        guard self.viewerDID != viewerDID else { return }
        self.viewerDID = viewerDID
        plan = nil
        error = nil
    }

    func refresh() async {
        guard SocialWireAPIEnvironment.proFeaturesReleased, let viewerDID else {
            plan = nil
            return
        }
        guard SocialWireAPIEnvironment.proGatingEnabled else {
            plan = .pro
            return
        }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let entitlement = try await gateway.fetchProEntitlement()
            guard entitlement.viewerDid == viewerDID else {
                throw SocialWireError.badResponse("Pro access was returned for a different account.")
            }
            plan = entitlement.plan
        } catch is CancellationError {
        } catch {
            plan = nil
            self.error = "Pro Access Could Not Be Verified."
        }
    }
}
