import Foundation

/// How a single article is presented inside a feed.
enum ArticleFeedCardStyle: Hashable, CaseIterable {
    /// Full-width hero that opens a chapter.
    case lead
    /// Image-on-top card placed in a responsive multi-column band.
    case grid
    /// Compact thumbnail-beside-text row.
    case row
}

/// A run of consecutive articles that share one presentation.
struct ArticleFeedSection<Item>: Identifiable {
    let id: Int
    let style: ArticleFeedCardStyle
    let items: [Item]
}

/// Slices a feed into repeating chapters — one lead story, a band of grid cards,
/// then a run of compact rows — so a long list never reads as a single texture.
enum ArticleFeedRhythm {
    /// Six divides evenly by every column count the band can resolve to (1, 2, or 3),
    /// so a full chapter never ends on a stretched lone card.
    static let gridCardsPerChapter = 6
    static let rowsPerChapter = 5

    /// The order styles cycle through within a chapter.
    private static let chapter: [ArticleFeedCardStyle] = [.lead, .grid, .row]

    static func sections<Item>(for items: [Item]) -> [ArticleFeedSection<Item>] {
        var sections: [ArticleFeedSection<Item>] = []
        var index = 0
        while index < items.count {
            for style in chapter where index < items.count {
                let count = min(capacity(of: style), items.count - index)
                sections.append(
                    ArticleFeedSection(
                        id: sections.count,
                        style: style,
                        items: Array(items[index ..< index + count])
                    )
                )
                index += count
            }
        }
        return sections
    }

    static func capacity(of style: ArticleFeedCardStyle) -> Int {
        switch style {
        case .lead: 1
        case .grid: gridCardsPerChapter
        case .row: rowsPerChapter
        }
    }
}
