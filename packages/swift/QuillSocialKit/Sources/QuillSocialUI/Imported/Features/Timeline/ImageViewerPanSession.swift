#if os(iOS)
import CoreGraphics

/// Converts a drag's cumulative screen-space translation into per-sample movement.
struct ImageViewerPanSession: Equatable {
    private var previousTranslation: CGSize? = .zero

    mutating func delta(for translation: CGSize) -> CGSize {
        guard translation.width.isFinite, translation.height.isFinite else {
            previousTranslation = nil
            return .zero
        }

        guard let previousTranslation else {
            self.previousTranslation = translation
            return .zero
        }

        let delta = CGSize(
            width: translation.width - previousTranslation.width,
            height: translation.height - previousTranslation.height
        )
        guard delta.width.isFinite, delta.height.isFinite else {
            self.previousTranslation = nil
            return .zero
        }

        self.previousTranslation = translation
        return delta
    }

    mutating func reset() {
        previousTranslation = .zero
    }
}

#endif
