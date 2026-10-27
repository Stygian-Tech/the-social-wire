#if os(iOS)
import SwiftUI

struct AltTextBadge: View {
    let hasAltText: Bool

    var body: some View {
        Group {
            if hasAltText {
                Label("Alt", systemImage: "text.bubble.fill")
            } else {
                Image(systemName: "apple.intelligence")
                    .accessibilityLabel("Generate Alt Text")
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.black.opacity(0.72), in: .capsule)
    }
}

#endif
