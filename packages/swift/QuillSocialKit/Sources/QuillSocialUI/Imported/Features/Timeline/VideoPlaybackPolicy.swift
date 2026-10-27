#if os(iOS)
import Foundation

enum VideoPlaybackPolicy: String, CaseIterable, Identifiable {
    case tapToPlay
    case mutedAutoplay

    var id: Self { self }
    var title: String {
        switch self {
        case .tapToPlay: "Tap to Play"
        case .mutedAutoplay: "Muted Autoplay"
        }
    }
}

#endif
