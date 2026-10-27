#if os(iOS)
import Feeds
import SwiftUI

struct ZoomableRemoteImage: View {
    let image: TimelineImage
    var isActive = true
    var onZoomChanged: (Bool) -> Void = { _ in }

    @State private var transform = ImageViewerTransform()
    @State private var settledScale: CGFloat = 1
    @State private var fittedImageSize: CGSize = .zero
    @GestureState private var livePan: ImageViewerLivePan?
    @Namespace private var viewportCoordinateSpace

    var body: some View {
        GeometryReader { geometry in
            TimelineImageMediaView(image: image, usesFullsize: true)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                    fittedImageSize = size
                    transform.setScale(transform.scale, imageSize: size, viewportSize: geometry.size)
                }
                .scaleEffect(transform.scale)
                .offset(transform.scale > 1 ? livePan?.transform.offset ?? transform.offset : .zero)
                .transaction { transaction in
                    if livePan != nil {
                        transaction.animation = nil
                        transaction.disablesAnimations = true
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .background(.black)
                .clipped()
                .contentShape(.rect)
                .simultaneousGesture(zoomGesture(in: geometry.size))
                // Recognize alongside pinch and tap so drag samples are not deferred until release.
                .simultaneousGesture(panGesture(in: geometry.size), including: transform.scale > 1 ? .all : .subviews)
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    withAnimation(.snappy) {
                        transform.setScale(transform.scale > 1 ? 1 : 2,
                                           imageSize: fittedImageSize, viewportSize: geometry.size)
                        settledScale = transform.scale
                    }
                })
                .onChange(of: geometry.size) { _, size in
                    transform.setScale(transform.scale, imageSize: fittedImageSize, viewportSize: size)
                }
                .onChange(of: livePan?.transform.offset) { _, offset in
                    guard isActive, transform.scale > 1, let offset else { return }
                    // Retain the last visible position for gesture cancellation;
                    // rendering itself reads GestureState directly above.
                    transform.pan(from: offset, translation: .zero,
                                  imageSize: fittedImageSize, viewportSize: geometry.size)
                }
        }
        .coordinateSpace(.named(viewportCoordinateSpace))
        .background(.black)
        .onChange(of: transform.scale > 1) { _, isZoomed in
            onZoomChanged(isZoomed)
        }
        .onChange(of: isActive) { _, active in
            if !active {
                transform.reset()
                settledScale = 1
            }
        }
        .onDisappear { onZoomChanged(false) }
        .accessibilityLabel(image.altText.isEmpty ? "Post Image" : image.altText)
        .accessibilityHint(transform.scale > 1 ? "Drag to explore the zoomed image. Double-tap to zoom out." : "Pinch or double-tap to zoom in.")
    }

    private func panGesture(in viewport: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(viewportCoordinateSpace))
            .updating($livePan) { value, state, transaction in
                guard transform.scale > 1 else { state = nil; return }
                transaction.animation = nil
                transaction.disablesAnimations = true
                if state == nil { state = ImageViewerLivePan(transform: transform) }
                state?.update(translation: value.translation, scale: transform.scale,
                              imageSize: fittedImageSize, viewportSize: viewport)
            }
            .onEnded { value in
                guard transform.scale > 1, var finalPan = livePan else { return }
                // Consume only any remaining movement in the final sample.
                finalPan.update(translation: value.translation, scale: transform.scale,
                                imageSize: fittedImageSize, viewportSize: viewport)
                transform.pan(from: finalPan.transform.offset, translation: .zero,
                              imageSize: fittedImageSize, viewportSize: viewport)
            }
    }

    private func zoomGesture(in viewport: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                transform.setScale(settledScale * value.magnification,
                                   imageSize: fittedImageSize, viewportSize: viewport)
            }
            .onEnded { _ in
                settledScale = transform.scale
            }
    }
}

#endif
