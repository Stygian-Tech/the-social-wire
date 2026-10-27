#if os(iOS)
import CoreGraphics

/// Keeps a zoomed, aspect-fitted image within its viewing area.
struct ImageViewerTransform: Equatable {
    private(set) var scale: CGFloat = 1
    private(set) var offset: CGSize = .zero

    mutating func setScale(_ scale: CGFloat, imageSize: CGSize, viewportSize: CGSize) {
        self.scale = scale.isFinite ? min(max(scale, 1), 5) : 1
        offset = clampedOffset(offset, imageSize: imageSize, viewportSize: viewportSize)
    }

    mutating func pan(
        from origin: CGSize,
        translation: CGSize,
        imageSize: CGSize,
        viewportSize: CGSize
    ) {
        offset = clampedOffset(
            CGSize(width: origin.width + translation.width, height: origin.height + translation.height),
            imageSize: imageSize,
            viewportSize: viewportSize
        )
    }

    mutating func reset() {
        scale = 1
        offset = .zero
    }

    private func clampedOffset(_ proposed: CGSize, imageSize: CGSize, viewportSize: CGSize) -> CGSize {
        guard scale > 1,
              imageSize.width.isFinite, imageSize.height.isFinite,
              viewportSize.width.isFinite, viewportSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0,
              viewportSize.width > 0, viewportSize.height > 0,
              proposed.width.isFinite, proposed.height.isFinite else { return .zero }

        let horizontalLimit = max(0, (imageSize.width * scale - viewportSize.width) / 2)
        let verticalLimit = max(0, (imageSize.height * scale - viewportSize.height) / 2)
        guard horizontalLimit.isFinite, verticalLimit.isFinite else { return .zero }

        return CGSize(
            width: min(max(proposed.width, -horizontalLimit), horizontalLimit),
            height: min(max(proposed.height, -verticalLimit), verticalLimit)
        )
    }
}

#endif
