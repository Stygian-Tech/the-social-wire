#if os(iOS)
import Feeds
import SwiftUI

struct QuotedPostCardView: View {
    let quote: TimelineQuote
    var onOpenThread: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            threadNavigationArea {
                HStack(spacing: 6) {
                    TimelineAvatarView(
                        avatarURL: quote.author.avatarURL,
                        actor: quote.author.did,
                        isLiveStreaming: quote.author.isLiveStreaming
                    )
                        .scaleEffect(0.72)
                        .frame(width: 32, height: 32)

                    VStack(alignment: .leading, spacing: 1) {
                        AccountDisplayNameView(author: quote.author)
                            .font(.subheadline)
                        Text(verbatim: "@\(quote.author.handle)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                AccountLabelsView(author: quote.author)

                RichPostTextView(text: quote.text, facets: quote.facets)
            }

            CashtagCardsView(text: quote.text, facets: quote.facets)

            if !quote.images.isEmpty {
                PostImagesView(images: quote.images)
            }

            if let video = quote.video {
                TimelineVideoView(video: video)
            }

            if let externalEmbed = quote.externalEmbed {
                ExternalEmbedView(embed: externalEmbed)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // Catch card padding and gaps behind the content, without placing a
            // navigation gesture above image, link, or chart interactions.
            if let onOpenThread {
                Button(action: onOpenThread) {
                    Rectangle().fill(.clear)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
            }
        }
        .background(.fill.quaternary, in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator, lineWidth: 0.5)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func threadNavigationArea<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if let onOpenThread {
            VStack(alignment: .leading, spacing: 6, content: content)
                .contentShape(.rect)
                .onTapGesture(perform: onOpenThread)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { onOpenThread() }
                .accessibilityHint("Opens the post thread")
        } else {
            VStack(alignment: .leading, spacing: 6, content: content)
        }
    }
}

#endif
