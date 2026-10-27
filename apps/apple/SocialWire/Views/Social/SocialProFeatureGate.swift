import SwiftUI

struct SocialProFeatureGate<Content: View>: View {
    @Bindable var entitlement: SocialProEntitlementModel
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack {
            if entitlement.isPro {
                content()
            } else {
                SocialProPaywallView(entitlement: entitlement)
            }
        }
        .task(id: entitlement.viewerDID) {
            if SocialWireAPIEnvironment.proFeaturesReleased, entitlement.plan == nil {
                await entitlement.refresh()
            }
        }
    }
}
