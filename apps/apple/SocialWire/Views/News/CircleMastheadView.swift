import SwiftUI

struct CircleMastheadView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("From People You Follow")
                .textCase(.uppercase)
                .font(.caption.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
            Text("Your Circle")
                .font(.largeTitle.bold())
        }
    }
}
