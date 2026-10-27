#if os(iOS)
import ATProtoCore
import Feeds
import SwiftUI

struct TimelinePostRow: View {
    let post: TimelinePost
    var showsReplyAttribution = true
    var connectsToPreviousAvatar = false
    var connectsToNextAvatar = false

    @Environment(\.routeNavigator) private var navigator
    @Environment(ThreadPositionStore.self) private var threadPositions
    @ScaledMetric(relativeTo: .body) private var avatarSize = 44.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TimelinePostCardView(
                post: post,
                threadPosition: threadPositions.position(for: post.uri),
                onOpenThread: openThreadAction,
                showsReplyAttribution: showsReplyAttribution
            )

            PostActionsView(post: post)
                .padding(.leading, avatarSize + 10)
                .padding(.top, 8)
                .padding(.bottom, 4)
        }
        .padding(.vertical, 6)
        .backgroundPreferenceValue(ThreadAvatarBoundsKey.self) { anchors in
            if let anchor = anchors[post.uri] {
                GeometryReader { geometry in
                    ThreadAvatarConnector(
                        avatarFrame: geometry[anchor],
                        connectsAbove: connectsToPreviousAvatar,
                        connectsBelow: connectsToNextAvatar
                    )
                    .stroke(.quaternary, lineWidth: 2)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .contain)
        .task(id: post.uri) {
            await threadPositions.load(for: post)
        }
    }

    private var openThreadAction: (() -> Void)? {
        guard let uri = try? ATURI(post.uri), navigator != nil else { return nil }
        return {
            Task { @MainActor in
                await Task.yield()
                navigator?(.thread(uri))
            }
        }
    }
}

#endif
