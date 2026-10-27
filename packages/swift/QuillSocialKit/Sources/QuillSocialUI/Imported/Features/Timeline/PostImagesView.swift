#if os(iOS)
import Feeds
import SwiftData
import SwiftUI

struct PostImagesView: View {
    let images: [TimelineImage]
    var opensFullSize = true

    @State private var selectedImageID: TimelineImage.ID?
    @State private var loadedAspectRatios: [TimelineImage.ID: CGFloat] = [:]
    @Query private var settings: [AppSettings]

    var body: some View {
        PhotoCollectionView(items: images, fullWidthAspectRatio: fullWidthAspectRatio) { image in
            imageTile(image)
        }
        .fullScreenCover(isPresented: fullScreenViewerBinding) {
            if let selectedImageID {
                FullScreenImageViewer(
                    images: images,
                    selectedImageID: selectedImageID
                )
            }
        }
    }

    @ViewBuilder
    private func imageTile(_ image: TimelineImage) -> some View {
        if opensFullSize {
            postImage(image)
                .contentShape(.rect)
                .onTapGesture { openViewer(for: image) }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { openViewer(for: image) }
                .accessibilityHint("Opens the full-size image")
                .overlay(alignment: .bottomTrailing) {
                    if !image.altText.isEmpty || allowsViewerGeneration {
                        altTextBadge(for: image)
                            .padding(8)
                    }
                }
        } else {
            postImage(image)
                .overlay(alignment: .bottomTrailing) {
                    if !image.altText.isEmpty || allowsViewerGeneration {
                        altTextBadge(for: image)
                            .padding(8)
                    }
                }
        }
    }

    private func altTextBadge(for image: TimelineImage) -> some View {
        Button {
            openViewer(for: image)
        } label: {
            AltTextBadge(hasAltText: !image.altText.isEmpty)
        }
        .buttonStyle(.plain)
    }

    private func fullWidthAspectRatio(_ image: TimelineImage) -> CGFloat? {
        let isGIF = image.originalGIFCID != nil || image.fullsizeURL.pathExtension.lowercased() == "gif"
        guard images.count == 1 || isGIF else {
            return nil
        }
        if let loadedRatio = loadedAspectRatios[image.id] { return loadedRatio }
        guard let width = image.width, let height = image.height, width > 0, height > 0 else {
            return isGIF ? 1 : 4 / 3
        }
        return CGFloat(width) / CGFloat(height)
    }

    private func postImage(_ image: TimelineImage) -> some View {
        PostImageView(
            image: image,
            displayAspectRatio: fullWidthAspectRatio(image) ?? 4 / 3,
            contentMode: fullWidthAspectRatio(image) == nil ? .fill : .fit
        ) { ratio in
            if fullWidthAspectRatio(image) != nil, ratio.isFinite, ratio > 0 {
                loadedAspectRatios[image.id] = ratio
            }
        }
    }

    private func openViewer(for image: TimelineImage) {
        selectedImageID = image.id
    }

    private var allowsViewerGeneration: Bool {
        settings.first?.allowsViewerAltTextGeneration ?? true
    }

    private var fullScreenViewerBinding: Binding<Bool> {
        Binding(
            get: { selectedImageID != nil },
            set: { if !$0 { selectedImageID = nil } }
        )
    }
}

#endif
