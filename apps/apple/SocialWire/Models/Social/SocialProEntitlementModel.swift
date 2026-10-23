import Foundation
import Observation

@MainActor
@Observable
final class SocialProEntitlementModel {
    @ObservationIgnored private var generation = UUID()
    private let gateway: SocialWireGatewayClient
    private(set) var viewerDID: String?
    private(set) var plan: SocialProEntitlement.Plan?
    private(set) var isLoading = false
    private(set) var error: String?

    var isPro: Bool {
        guard SocialWireAPIEnvironment.proGatingEnabled else { return viewerDID != nil }
        return plan == .pro
    }

    init(gateway: SocialWireGatewayClient) {
        self.gateway = gateway
    }

    func bind(viewerDID: String?) {
        guard self.viewerDID != viewerDID else { return }
        reset(viewerDID: viewerDID)
    }

    func reset(viewerDID: String?) {
        generation = UUID()
        self.viewerDID = viewerDID
        isLoading = false
        plan = nil
        error = nil
    }

    func refresh() async {
        let current = generation
        guard let viewerDID else {
            plan = nil
            return
        }
        guard SocialWireAPIEnvironment.proGatingEnabled else {
            plan = .pro
            return
        }
        isLoading = true
        error = nil
        defer { if generation == current { isLoading = false } }
        do {
            let entitlement = try await gateway.fetchProEntitlement()
            guard generation == current else { return }
            guard entitlement.viewerDid == viewerDID else {
                throw SocialWireError.badResponse("Pro access was returned for a different account.")
            }
            plan = entitlement.plan
        } catch is CancellationError {
        } catch {
            guard generation == current else { return }
            plan = nil
            self.error = "Pro Access Could Not Be Verified."
        }
    }
}
