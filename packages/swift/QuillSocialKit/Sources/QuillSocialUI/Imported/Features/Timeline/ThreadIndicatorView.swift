#if os(iOS)
import SwiftUI

struct ThreadIndicatorView: View {
    var body: some View {
        Capsule()
            .fill(Color.accentColor.opacity(0.32))
            .frame(width: 3)
            .frame(maxHeight: .infinity)
            .padding(.vertical, 4)
            .accessibilityHidden(true)
    }
}

#endif
