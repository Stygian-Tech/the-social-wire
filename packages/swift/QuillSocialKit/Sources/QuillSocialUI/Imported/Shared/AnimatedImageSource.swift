#if os(iOS)
import Foundation

/// A data replacement is a new request even when there is no remote URL.
enum AnimatedImageSource: Hashable, Sendable {
    case remote(URL)
    case bytes(Data)
}

#endif
