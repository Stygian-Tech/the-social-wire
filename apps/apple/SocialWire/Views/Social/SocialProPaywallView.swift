import SwiftUI

struct SocialProPaywallView: View {
    @Bindable var entitlement: SocialProEntitlementModel

    var body: some View {
        ContentUnavailableView {
            Label("Social Wire Pro", systemImage: "lock.fill")
        } description: {
            if !SocialWireAPIEnvironment.proFeaturesReleased {
                Text("Pro features are not available in this release.")
            } else if entitlement.isLoading {
                Text("Checking Pro Access…")
            } else if entitlement.error != nil {
                Text("Pro access could not be verified. Please retry.")
            } else {
                Text("Tools and multi-account support are available with Pro. Subscriptions are coming soon.")
            }
        } actions: {
            if SocialWireAPIEnvironment.proFeaturesReleased, !entitlement.isLoading {
                Button("Retry Pro Access") { Task { await entitlement.refresh() } }
                    .buttonStyle(.bordered)
            }
        }
        .accessibilityIdentifier("social-pro-paywall")
    }
}
