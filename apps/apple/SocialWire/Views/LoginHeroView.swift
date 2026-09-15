import SwiftUI

struct LoginHeroView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let motionManager: LoginMotionSource
    let isCompact: Bool

    var body: some View {
        VStack(spacing: isCompact ? 8 : 14) {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !usesDeviceMotion)) { _ in
                LoginLogoSurface(tilt: motionManager.tilt(enabled: usesDeviceMotion))
            }
            .frame(width: 160, height: isCompact ? 88 : 160)
            .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("Welcome to The\u{00A0}Social\u{00A0}Wire")
                    .font(isCompact ? .title2.bold() : .largeTitle.bold())
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.8)

                if !isCompact {
                    Text("Your feed. Your people. Across the open social web.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: isCompact)
    }

    private var usesDeviceMotion: Bool {
        !reduceMotion && motionManager.isDeviceMotionAvailable
    }
}

private struct LoginLogoSurface: View {
    let tilt: SIMD2<Float>

    var body: some View {
        Image("SocialWireMark")
            .resizable()
            .scaledToFill()
            .frame(width: 148, height: 148)
            .clipShape(.circle)
            .colorEffect(
                ShaderLibrary.loginReflection(
                    .float2(tilt.x, tilt.y),
                    .float(148)
                )
            )
            .overlay {
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.6), .white.opacity(0.08)],
                            startPoint: UnitPoint(x: 0.5 + Double(tilt.x) * 0.35, y: 0),
                            endPoint: UnitPoint(x: 0.5 - Double(tilt.x) * 0.35, y: 1)
                        ),
                        lineWidth: 1
                    )
            }
            .rotation3DEffect(
                .degrees(Double(tilt.y) * -3.5),
                axis: (x: 1, y: 0, z: 0),
                perspective: 0.3
            )
            .rotation3DEffect(
                .degrees(Double(tilt.x) * 3.5),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.3
            )
            .shadow(color: .indigo.opacity(0.18), radius: 18, y: 8)
    }
}
