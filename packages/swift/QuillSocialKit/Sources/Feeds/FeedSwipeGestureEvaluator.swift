import CoreGraphics

public enum FeedSwipeGestureEvaluator {
    public static func destinationIndex(
        currentIndex: Int,
        feedCount: Int,
        translation: CGSize,
        predictedEndTranslation: CGSize
    ) -> Int? {
        guard feedCount > 1 else { return nil }

        guard isHorizontalIntent(translation: translation) else { return nil }

        let horizontalDistance = abs(translation.width)
        let predictedDistance = abs(predictedEndTranslation.width)
        let isDirectCommit = horizontalDistance >= 88
        let projectedDirectionMatches = translation.width.sign == predictedEndTranslation.width.sign
        let projectedHorizontalIntent = predictedDistance > abs(predictedEndTranslation.height) * 1.75
        let isProjectedCommit = horizontalDistance >= 36
            && predictedDistance >= 140
            && projectedDirectionMatches
            && projectedHorizontalIntent
        guard isDirectCommit || isProjectedCommit else { return nil }

        let destination = translation.width < 0 ? currentIndex + 1 : currentIndex - 1
        guard (0..<feedCount).contains(destination) else { return nil }
        return destination
    }

    public static func isHorizontalIntent(translation: CGSize) -> Bool {
        let horizontalDistance = abs(translation.width)
        let verticalDistance = abs(translation.height)
        return horizontalDistance >= 16 && horizontalDistance > verticalDistance * 1.75
    }
}
