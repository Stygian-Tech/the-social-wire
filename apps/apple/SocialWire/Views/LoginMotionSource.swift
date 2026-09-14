#if os(iOS)
import CoreMotion
#endif

/// The login artwork remains still on platforms without device motion.
@MainActor
final class LoginMotionSource {
#if os(iOS)
    private let manager = CMMotionManager()
#endif

    var isDeviceMotionAvailable: Bool {
#if os(iOS)
        manager.isDeviceMotionAvailable
#else
        false
#endif
    }

    func start() {
#if os(iOS)
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates()
#endif
    }

    func stop() {
#if os(iOS)
        manager.stopDeviceMotionUpdates()
#endif
    }

    func tilt(enabled: Bool) -> SIMD2<Float> {
#if os(iOS)
        guard enabled, let attitude = manager.deviceMotion?.attitude else { return .zero }
        return SIMD2(Self.normalize(attitude.roll), Self.normalize(attitude.pitch))
#else
        return .zero
#endif
    }

    private static func normalize(_ radians: Double) -> Float {
        Float(max(-1, min(1, radians / 0.45)))
    }
}
