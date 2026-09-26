import SwiftUI

struct LoginGlassCardModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            GlassEffectContainer(spacing: 18) {
                content
                    .glassEffect(.regular, in: .rect(cornerRadius: 24))
            }
        } else {
            content
                .background(.regularMaterial, in: .rect(cornerRadius: 24))
                .overlay {
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(.white.opacity(0.18), lineWidth: 1)
                }
        }
    }
}

struct LoginGlassInputModifier: ViewModifier {
    let isFocused: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content
                .glassEffect(
                    .regular.tint(isFocused ? .indigo.opacity(0.12) : .clear).interactive(),
                    in: .rect(cornerRadius: 12)
                )
        } else {
            content
                .background(.background, in: .rect(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            isFocused ? Color.indigo : Color.secondary.opacity(0.25),
                            lineWidth: isFocused ? 2 : 1
                        )
                }
        }
    }
}

extension View {
    func loginGlassCard() -> some View {
        modifier(LoginGlassCardModifier())
    }

    func loginGlassInput(isFocused: Bool) -> some View {
        modifier(LoginGlassInputModifier(isFocused: isFocused))
    }
}
