#if os(iOS)
import ATProtoCore
import Feeds
import SwiftUI

/// Only posts already delivered by this feed appear here; opening the thread
/// supplies the rest of the conversation without changing feed membership.
struct TimelineThreadGroupView: View {
    let group: TimelineThreadGroup

    @Environment(\.routeNavigator) private var navigator
    @ScaledMetric(relativeTo: .body) private var avatarSize = 44.0
    @State private var openThreadFeedback = 0

    private var isConversation: Bool {
        group.posts.count > 1 || group.hasMissingRoot
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if isConversation {
                HStack(spacing: 6) {
                    Label("Thread", systemImage: "bubble.left.and.bubble.right")
                    if group.posts.count > 1 {
                        Text("· \(group.posts.count) Posts")
                    }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
            }

            ForEach(Array(group.posts.enumerated()), id: \.element.id) { index, post in
                VStack(alignment: .leading, spacing: 0) {
                    if index > 0 {
                        if post.replyParentURI == group.posts[index - 1].uri {
                            Rectangle()
                                .fill(.quaternary)
                                .frame(width: 2, height: 18)
                                .padding(.leading, avatarSize / 2 - 1)
                                .accessibilityHidden(true)
                        } else {
                            // Siblings and missing ancestors must not look like
                            // consecutive links in a reply chain.
                            Divider()
                                .padding(.leading, avatarSize + 10)
                                .padding(.vertical, 6)
                        }
                    }

                    TimelinePostRow(
                        post: post,
                        showsReplyAttribution: index == 0
                            || post.replyParentURI != group.posts[index - 1].uri,
                        connectsToPreviousAvatar: index > 0
                            && post.replyParentURI == group.posts[index - 1].uri,
                        connectsToNextAvatar: index + 1 < group.posts.count
                            && group.posts[index + 1].replyParentURI == post.uri
                    )
                }
            }

            if isConversation, let uri = try? ATURI(group.id), navigator != nil {
                Button {
                    openThreadFeedback += 1
                    navigator?(.thread(uri))
                } label: {
                    Label(group.hasMissingRoot ? "View Full Thread" : "View Thread",
                          systemImage: "arrow.right")
                        .font(.subheadline.weight(.medium))
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .padding(.leading, avatarSize + 10)
                .accessibilityHint("Opens the full conversation, including posts outside this feed")
            }
        }
        .padding(.vertical, isConversation ? 6 : 0)
        .sensoryFeedback(.selection, trigger: openThreadFeedback)
    }
}

#endif
