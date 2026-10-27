#if os(iOS)
import SwiftUI

struct ThemeChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption)
            .foregroundStyle(.tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.2 : 0.12), in: .capsule)
            .overlay {
                Capsule()
                    .stroke(Color.accentColor.opacity(0.24), lineWidth: 1)
            }
            .contentShape(.capsule)
    }
}

#endif
