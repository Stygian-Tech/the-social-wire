import CoreGraphics

/// Maximum content measures for the article surfaces. A Mac window is wide enough
/// for a multi-column editorial rhythm, so both surfaces share one wider measure
/// there while keeping their established widths on iOS.
enum ArticleReadingWidth {
    /// Feed lists: Library, Subscribed, Following.
    static var feed: CGFloat {
        #if os(macOS)
        1_100
        #else
        700
        #endif
    }

    /// Editorial tabs: The Wire and Circle.
    static var editorial: CGFloat {
        #if os(macOS)
        1_100
        #else
        900
        #endif
    }
}
