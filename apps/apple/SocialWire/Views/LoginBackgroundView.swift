import SwiftUI

struct LoginBackgroundView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let motionManager: LoginMotionSource

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !usesDeviceMotion)) { _ in
            let tilt = motionManager.tilt(enabled: usesDeviceMotion)

            ZStack {
                Color(.systemGroupedBackground)

                Circle()
                    .fill(Color.indigo.opacity(0.2))
                    .frame(width: 400, height: 400)
                    .blur(radius: 80)
                    .offset(
                        x: -170 + CGFloat(tilt.x) * 90,
                        y: -280 + CGFloat(tilt.y) * 70
                    )

                Circle()
                    .fill(Color.orange.opacity(0.16))
                    .frame(width: 340, height: 340)
                    .blur(radius: 90)
                    .offset(
                        x: 190 - CGFloat(tilt.x) * 75,
                        y: 310 - CGFloat(tilt.y) * 60
                    )
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private var usesDeviceMotion: Bool {
        !reduceMotion && motionManager.isDeviceMotionAvailable
    }
}

