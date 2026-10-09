import CoreGraphics

/// Maximum content measures for article surfaces. Wider iPad and Mac layouts use
/// an editorial rhythm while iPhone keeps a comfortable single-column measure.
enum ArticleReadingWidth {
    /// Feed lists: Library, Subscribed, Following.
    static var feed: CGFloat {
        #if os(macOS) || os(iOS)
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
