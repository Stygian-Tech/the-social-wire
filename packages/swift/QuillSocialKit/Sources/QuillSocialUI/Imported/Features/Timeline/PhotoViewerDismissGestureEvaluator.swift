#if os(iOS)
import CoreGraphics

struct PhotoViewerDismissGestureEvaluator {
    static func isVerticalIntent(_ translation: CGSize) -> Bool {
        abs(translation.height) > abs(translation.width)
    }

    static func shouldDismiss(translation: CGSize, predictedEndTranslation: CGSize) -> Bool {
        guard isVerticalIntent(translation) else { return false }
        return abs(translation.height) >= 120 || abs(predictedEndTranslation.height) >= 240
    }
}

#endif
