#if os(iOS)
import Feeds
import SwiftUI

struct TimelinePostCardView: View {
    let post: TimelinePost
    var threadPosition: (position: Int, total: Int)? = nil
    var onOpenThread: (() -> Void)? = nil
    var showsReplyAttribution = true
    @ScaledMetric(relativeTo: .body) private var avatarSize = 44.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let repostedBy = post.repostedBy {
                ProfileAttributionChip(
                    title: "Reposted by",
                    avatarURL: repostedBy.avatarURL,
                    handle: repostedBy.handle
                )
                .padding(.leading, 52)
            }

            if showsReplyAttribution, let replyingTo = post.replyingTo {
                ProfileAttributionChip(
                    title: "Replying to",
                    avatarURL: replyingTo.avatarURL,
                    handle: replyingTo.handle
                )
                .padding(.leading, 52)
            }

            HStack(alignment: .top, spacing: 10) {
                TimelineAvatarView(
                    avatarURL: post.author.avatarURL,
                    actor: post.author.did,
                    isLiveStreaming: post.author.isLiveStreaming
                )
                .anchorPreference(key: ThreadAvatarBoundsKey.self, value: .bounds) {
                    [post.uri: $0]
                }

                VStack(alignment: .leading, spacing: 6) {
                    threadNavigationArea {
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
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            CashtagCardsView(text: post.text, facets: post.facets)

            if !post.images.isEmpty || post.video != nil || post.externalEmbed != nil || post.quote != nil {
                VStack(alignment: .leading, spacing: 6) {
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
                }
                .padding(.leading, avatarSize + 10)
            }
        }
        .contentShape(.rect)
        .background {
            // The parent owns only otherwise-unused card space. Embedded quote,
            // media, and link controls keep their own foreground hit regions.
            if let onOpenThread {
                Button(action: onOpenThread) {
                    Rectangle().fill(.clear)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
            }
        }
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
