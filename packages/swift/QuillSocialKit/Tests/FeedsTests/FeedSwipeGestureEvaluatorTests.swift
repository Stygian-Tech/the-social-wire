import CoreGraphics
import Feeds
import Testing

struct FeedSwipeGestureEvaluatorTests {
    @Test func horizontalSwipeAdvancesToTheNextFeed() {
        let result = FeedSwipeGestureEvaluator.destinationIndex(
            currentIndex: 0,
            feedCount: 3,
            translation: CGSize(width: -96, height: 8),
            predictedEndTranslation: CGSize(width: -110, height: 8)
        )

        #expect(result == 1)
    }

    @Test func verticalScrollingDoesNotChangeFeeds() {
        let result = FeedSwipeGestureEvaluator.destinationIndex(
            currentIndex: 1,
            feedCount: 3,
            translation: CGSize(width: 40, height: 70),
            predictedEndTranslation: CGSize(width: 100, height: 90)
        )

        #expect(result == nil)
    }

    @Test func horizontalIntentRejectsTapsBeforeTheSwipeCommits() {
        let rejectsTap = FeedSwipeGestureEvaluator.isHorizontalIntent(
            translation: CGSize(width: 18, height: 2)
        )

        #expect(rejectsTap)
    }

    @Test func verticalIntentDoesNotRejectTaps() {
        let rejectsTap = FeedSwipeGestureEvaluator.isHorizontalIntent(
            translation: CGSize(width: 8, height: 18)
        )

        #expect(!rejectsTap)
    }

    @Test func swipeCannotMovePastAnEdge() {
        let result = FeedSwipeGestureEvaluator.destinationIndex(
            currentIndex: 0,
            feedCount: 3,
            translation: CGSize(width: 70, height: 0),
            predictedEndTranslation: CGSize(width: 100, height: 0)
        )

        #expect(result == nil)
    }

    @Test func projectedSwipeCommitsAfterIntentIsEstablished() {
        let result = FeedSwipeGestureEvaluator.destinationIndex(
            currentIndex: 1,
            feedCount: 3,
            translation: CGSize(width: 40, height: 2),
            predictedEndTranslation: CGSize(width: 150, height: 3)
        )

        #expect(result == 0)
    }

    @Test func diagonalScrollDoesNotEstablishHorizontalIntent() {
        #expect(!FeedSwipeGestureEvaluator.isHorizontalIntent(
            translation: CGSize(width: 24, height: 16)
        ))
    }

    @Test func shortHorizontalDragDoesNotCommit() {
        let result = FeedSwipeGestureEvaluator.destinationIndex(
            currentIndex: 1,
            feedCount: 3,
            translation: CGSize(width: 60, height: 4),
            predictedEndTranslation: CGSize(width: 100, height: 5)
        )

        #expect(result == nil)
    }

    @Test func diagonalProjectionDoesNotCommit() {
        let result = FeedSwipeGestureEvaluator.destinationIndex(
            currentIndex: 1,
            feedCount: 3,
            translation: CGSize(width: 40, height: 4),
            predictedEndTranslation: CGSize(width: 160, height: 120)
        )

        #expect(result == nil)
    }
}
