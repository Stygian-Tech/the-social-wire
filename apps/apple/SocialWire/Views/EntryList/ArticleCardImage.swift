import SwiftUI

/// Shared metrics so the feed cards and the editorial tabs stay visually identical.
enum ArticleCardMetrics {
    /// Article artwork is overwhelmingly 16:9; matching it leaves nothing to crop.
    static let widescreen: CGFloat = 16 / 9
    static let padding: CGFloat = 14
    static let spacing: CGFloat = 7
}

/// Sizes content to the full proposed width at a fixed aspect ratio, ignoring any
/// proposed height.
///
/// `aspectRatio(_:contentMode:.fit)` cannot be used here: it fits within *both*
/// proposed dimensions, so it narrows the width whenever a container proposes a
/// shorter height. `EditorialCardLayout` proposes every card in a row the row's
/// shared height, which left each banner inset from its own card's trailing edge.
struct WidthDrivenAspectRatio: Layout {
    let ratio: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.first?.sizeThatFits(.unspecified).width ?? 0
        return CGSize(width: width, height: width / ratio)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        for subview in subviews {
            subview.place(
                at: CGPoint(x: bounds.midX, y: bounds.midY),
                anchor: .center,
                proposal: ProposedViewSize(bounds.size)
            )
        }
    }
}

/// Banner artwork for the article cards.
///
/// Sizes by aspect ratio rather than a fixed height: these cards appear at widths
/// from a 240pt rail card to a 534pt lead, and any single height would letterbox
/// most of them. Always draws a placeholder so a story without artwork keeps the
/// same silhouette as its neighbours.
struct ArticleCardImage: View {
    let urls: [URL]
    var aspectRatio: CGFloat = ArticleCardMetrics.widescreen

    var body: some View {
        WidthDrivenAspectRatio(ratio: aspectRatio) {
            Rectangle()
                .fill(Color(.tertiarySystemFill))
                .overlay {
                    if urls.isEmpty {
                        Image(systemName: "photo")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                    } else {
                        CachedRemoteImage(urls: urls, maxPixelSize: 1_000) {
                            Color.clear
                        }
                        .scaledToFill()
                    }
                }
        }
        .clipped()
        .accessibilityHidden(true)
    }
}
