#if os(iOS)
import CoreGraphics

/// Holds the visible image transform throughout a drag, including movement at clamped edges.
struct ImageViewerLivePan: Equatable {
    private(set) var transform: ImageViewerTransform
    private var session = ImageViewerPanSession()

    init(transform: ImageViewerTransform) {
        self.transform = transform
    }

    mutating func update(
        translation: CGSize,
        scale: CGFloat,
        imageSize: CGSize,
        viewportSize: CGSize
    ) {
        transform.setScale(scale, imageSize: imageSize, viewportSize: viewportSize)
        transform.pan(
            from: transform.offset,
            translation: session.delta(for: translation),
            imageSize: imageSize,
            viewportSize: viewportSize
        )
    }
}

#endif
