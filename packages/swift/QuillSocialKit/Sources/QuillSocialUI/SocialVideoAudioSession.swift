#if os(iOS)
import AVFoundation

/// Inline social videos share audio with music and other apps, without ducking it.
@MainActor
public enum SocialVideoAudioSession {
    public static func prepareForPlayback() throws {
        let session = AVAudioSession.sharedInstance()
        try prepareForPlayback(
            configure: { try session.setCategory($0, mode: $1, options: $2) },
            activate: { try session.setActive(true) }
        )
    }

    static func prepareForPlayback(
        configure: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions) throws -> Void,
        activate: () throws -> Void
    ) throws {
        try configure(.playback, .moviePlayback, [.mixWithOthers])
        try activate()
    }
}
#endif
