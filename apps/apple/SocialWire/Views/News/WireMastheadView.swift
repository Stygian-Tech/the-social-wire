import SwiftUI

struct WireMastheadView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("The Social Wire")
                .textCase(.uppercase)
                .font(.caption.weight(.semibold))
                .tracking(1.4)
                .foregroundStyle(.secondary)
            Text("The Wire")
                .font(.largeTitle.bold())
        }
        .accessibilityElement(children: .combine)
    }
}
