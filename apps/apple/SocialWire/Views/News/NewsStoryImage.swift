import SwiftUI

struct NewsStoryImage: View {
    let urls: [URL]
    let height: CGFloat

    var body: some View {
        if !urls.isEmpty {
            // The frame owns layout; a loaded image must never widen its card.
            Rectangle()
                .fill(.quaternary)
                .frame(height: height)
                .overlay {
                    CachedRemoteImage(urls: urls, maxPixelSize: 1_000) {
                        Color.clear
                    }
                    .scaledToFill()
                }
                .clipShape(.rect(cornerRadius: 14))
                .accessibilityHidden(true)
        }
    }
}
