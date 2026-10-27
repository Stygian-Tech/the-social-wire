#if os(iOS)
import SwiftUI

struct PhotoCollectionView<Item: Identifiable, Tile: View>: View {
    let items: [Item]
    var spacing: CGFloat = 8
    var aspectRatio: CGFloat = 4 / 3
    var carouselThreshold = 4
    var fullWidthAspectRatio: (Item) -> CGFloat? = { _ in nil }
    @ViewBuilder let tile: (Item) -> Tile

    var body: some View {
        if items.contains(where: { fullWidthAspectRatio($0) != nil }) {
            // Animated media needs its natural height and the entire card width.
            VStack(spacing: spacing) {
                ForEach(items) { item in
                    framedTile(item)
                }
            }
        } else if items.count > carouselThreshold {
            ScrollView(.horizontal) {
                LazyHStack(spacing: spacing) {
                    ForEach(items) { item in
                        framedTile(item)
                            .containerRelativeFrame(.horizontal) { length, _ in
                                length * 0.82
                            }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
            .clipShape(.rect)
        } else {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(minimum: 0), spacing: spacing),
                    count: items.count == 1 ? 1 : 2
                ),
                spacing: spacing
            ) {
                ForEach(items) { item in
                    framedTile(item)
                }
            }
        }
    }

    private func framedTile(_ item: Item) -> some View {
        FeedMediaViewport(aspectRatio: fullWidthAspectRatio(item) ?? aspectRatio) {
            tile(item)
        }
    }
}

#endif
