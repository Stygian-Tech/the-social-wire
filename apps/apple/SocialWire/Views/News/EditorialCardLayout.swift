import SwiftUI

/// A responsive editorial layout that chooses a natural column count from the available width.
struct EditorialCardLayout: Layout {
    let spacing: CGFloat
    let minimumCardWidth: CGFloat

    init(spacing: CGFloat = 16, minimumCardWidth: CGFloat = 220) {
        self.spacing = spacing
        self.minimumCardWidth = minimumCardWidth
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minimumCardWidth
        let rows = rowRanges(itemCount: subviews.count, availableWidth: width)
        let height = rows.reduce(CGFloat.zero) { result, row in
            result + rowHeight(row, width: width, subviews: subviews)
        } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var y = bounds.minY
        for row in rowRanges(itemCount: subviews.count, availableWidth: bounds.width) {
            let cardWidth = widthPerCard(count: row.count, availableWidth: bounds.width)
            let height = rowHeight(row, width: bounds.width, subviews: subviews)
            for (column, index) in row.enumerated() {
                subviews[index].place(
                    at: CGPoint(x: bounds.minX + CGFloat(column) * (cardWidth + spacing), y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: cardWidth, height: height)
                )
            }
            y += height + spacing
        }
    }

    private func rowRanges(itemCount: Int, availableWidth: CGFloat) -> [Range<Int>] {
        let columnCount = max(
            1,
            Int((availableWidth + spacing) / (minimumCardWidth + spacing))
        )
        var rows: [Range<Int>] = []
        var index = 0
        while index < itemCount {
            let count = min(columnCount, itemCount - index)
            rows.append(index ..< index + count)
            index += count
        }
        return rows
    }

    private func widthPerCard(count: Int, availableWidth: CGFloat) -> CGFloat {
        (availableWidth - spacing * CGFloat(max(0, count - 1))) / CGFloat(max(1, count))
    }

    private func rowHeight(_ row: Range<Int>, width: CGFloat, subviews: Subviews) -> CGFloat {
        let cardWidth = widthPerCard(count: row.count, availableWidth: width)
        return row.reduce(CGFloat.zero) { height, index in
            max(height, subviews[index].sizeThatFits(.init(width: cardWidth, height: nil)).height)
        }
    }
}
