#if os(iOS)
import Feeds
import SwiftUI

/// Bounded notification content; the full post and media remain available in its thread.
struct NotificationPostPreviewView: View {
    private let text: String
    private let facets: [TimelineFacet]
    private let thumbnailURL: URL?
    private let thumbnailDescription: String
    private let mediaTitle: String?
    private let isVideo: Bool
    private let onOpen: () -> Void
    @ScaledMetric(relativeTo: .subheadline) private var maximumTextHeight = 66.0

    init(post: TimelinePost, onOpen: @escaping () -> Void) {
        text = post.text
        facets = post.facets
        thumbnailURL = post.images.first?.thumbnailURL ?? post.video?.thumbnailURL ?? post.externalEmbed?.thumbnailURL
        thumbnailDescription = post.images.first?.altText ?? post.video?.altText ?? post.externalEmbed?.title ?? "Post Image"
        mediaTitle = post.externalEmbed?.title ?? (post.video != nil ? "Video" : nil)
            ?? (post.images.isEmpty ? nil : "\(post.images.count) \(post.images.count == 1 ? "Photo" : "Photos")")
        isVideo = post.video != nil
        self.onOpen = onOpen
    }

    init(quote: TimelineQuote, onOpen: @escaping () -> Void) {
        text = quote.text
        facets = quote.facets
        thumbnailURL = quote.images.first?.thumbnailURL ?? quote.video?.thumbnailURL ?? quote.externalEmbed?.thumbnailURL
        thumbnailDescription = quote.images.first?.altText ?? quote.video?.altText ?? quote.externalEmbed?.title ?? "Post Image"
        mediaTitle = quote.externalEmbed?.title ?? (quote.video != nil ? "Video" : nil)
            ?? (quote.images.isEmpty ? nil : "\(quote.images.count) \(quote.images.count == 1 ? "Photo" : "Photos")")
        isVideo = quote.video != nil
        self.onOpen = onOpen
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    if !text.isEmpty {
                        RichPostTextView(text: text, facets: facets)
                            .font(.subheadline)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxHeight: maximumTextHeight, alignment: .top)
                            .clipped()
                    }
                    if let mediaTitle {
                        Label(mediaTitle, systemImage: isVideo ? "play.rectangle" : "paperclip")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    } else if text.isEmpty {
                        Text("View Post").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let thumbnailURL {
                    AsyncImage(url: thumbnailURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.secondary.opacity(0.1)
                    }
                    .frame(width: 50, height: 50)
                    .clipShape(.rect(cornerRadius: 7))
                    .overlay {
                        if isVideo {
                            Image(systemName: "play.circle.fill")
                                .foregroundStyle(.white).shadow(radius: 2)
                        }
                    }
                    .accessibilityLabel(thumbnailDescription.isEmpty ? "Post Image" : thumbnailDescription)
                }
            }
            .frame(minHeight: 44, alignment: .topLeading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(previewDescription)
    }

    private var previewDescription: String {
        let parts = [text, mediaTitle, thumbnailURL == nil ? nil : thumbnailDescription]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? "View Post" : parts.joined(separator: ". ")
    }
}
#endif
