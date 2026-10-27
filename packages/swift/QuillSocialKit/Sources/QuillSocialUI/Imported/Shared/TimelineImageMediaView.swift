#if os(iOS)
import Feeds
import SwiftUI

/// Keeps the App View identity while playing the original GIF blob from its author's PDS.
struct TimelineImageMediaView: View {
    let image: TimelineImage
    var usesFullsize = false
    var contentMode: ContentMode = .fit
    var onAspectRatioLoaded: ((CGFloat) -> Void)?

    @State private var originalURL: URL?

    var body: some View {
        AnimatedImageView(
            url: originalURL ?? (usesFullsize ? image.fullsizeURL : image.thumbnailURL),
            contentMode: contentMode,
            onAspectRatioLoaded: onAspectRatioLoaded
        )
            .task(id: image) {
                originalURL = nil
                guard let did = image.originalGIFDID, let cid = image.originalGIFCID else { return }
                let url = try? await GIFBlobURLCache.shared.url(did: did, cid: cid)
                guard !Task.isCancelled else { return }
                originalURL = url
            }
    }
}

#endif
