#if os(iOS)
import Feeds
import SwiftUI

struct PostImageView: View {
    let image: TimelineImage
    var displayAspectRatio: CGFloat?
    var contentMode: ContentMode = .fit
    var onAspectRatioLoaded: ((CGFloat) -> Void)?

    init(
        image: TimelineImage,
        displayAspectRatio: CGFloat? = nil,
        contentMode: ContentMode = .fit,
        onAspectRatioLoaded: ((CGFloat) -> Void)? = nil
    ) {
        self.image = image
        self.displayAspectRatio = displayAspectRatio
        self.contentMode = contentMode
        self.onAspectRatioLoaded = onAspectRatioLoaded
    }

    var body: some View {
        FeedMediaViewport(aspectRatio: displayAspectRatio ?? aspectRatio, cornerRadius: 10) {
            TimelineImageMediaView(
                image: image,
                contentMode: contentMode,
                onAspectRatioLoaded: onAspectRatioLoaded
            )
        }
        .background(.fill.tertiary)
        .accessibilityLabel(image.altText.isEmpty ? "Post Image" : image.altText)
    }

    private var aspectRatio: CGFloat {
        guard let width = image.width, let height = image.height, height > 0 else { return 16 / 9 }
        return CGFloat(width) / CGFloat(height)
    }
}

#endif
