#if os(iOS)
import Feeds
import SwiftUI

struct ThreadPostRow: View {
    let entry: ThreadEntry
    let threadPosition: (position: Int, total: Int)?

    @ScaledMetric(relativeTo: .body) private var avatarSize = 44.0

    var body: some View {
        let post = entry.post

        HStack(alignment: .top, spacing: 8) {
            if entry.depth > 0 {
                ThreadIndicatorView()
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    TimelineAvatarView(
                        avatarURL: post.author.avatarURL,
                        actor: post.author.did,
                        isLiveStreaming: post.author.isLiveStreaming
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            AccountDisplayNameView(author: post.author)
                            Text(verbatim: "@\(post.author.handle)")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .layoutPriority(-1)
                            SocialTimestampView(date: post.createdAt)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                        }
                        .font(.subheadline)

                        AccountLabelsView(
                            author: post.author,
                            moderationLabels: post.labels
                        )

                        RichPostTextView(text: post.text, facets: post.facets)
                            .font(.body)
                            .textSelection(.enabled)
                            .padding(.trailing, threadPosition == nil ? 0 : 58)
                            .overlay(alignment: .bottomTrailing) {
                                if let threadPosition {
                                    ThreadDepthChip(
                                        position: threadPosition.position,
                                        total: threadPosition.total
                                    )
                                    .fixedSize()
                                    .offset(y: 2)
                                }
                            }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                CashtagCardsView(text: post.text, facets: post.facets)

                VStack(alignment: .leading, spacing: 8) {
                    if !post.images.isEmpty {
                        PostImagesView(images: post.images)
                    }

                    if let video = post.video {
                        TimelineVideoView(video: video)
                    }

                    if let externalEmbed = post.externalEmbed {
                        ExternalEmbedView(embed: externalEmbed)
                    }

                    if let quote = post.quote {
                        QuotedPostView(quote: quote)
                    }

                    PostActionsView(post: post)
                        .padding(.top, 4)
                }
                .padding(.leading, avatarSize + 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, entry.isFocused ? 10 : 4)
        .accessibilityElement(children: .contain)
    }
}

#endif
