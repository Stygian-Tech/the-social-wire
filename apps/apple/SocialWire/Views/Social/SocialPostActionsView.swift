import SwiftUI

struct SocialPostActionsView: View {
    let post: SocialPost
    let like: () -> Void
    let repost: () -> Void
    let reply: () -> Void
    let quote: () -> Void

    var body: some View {
        HStack {
            action("bubble.left", count: post.replyCount, label: "Reply", action: reply)
            action(post.viewerRepostURI == nil ? "arrow.2.squarepath" : "arrow.2.squarepath", count: post.repostCount, label: post.viewerRepostURI == nil ? "Repost" : "Undo Repost", action: repost)
                .foregroundStyle(post.viewerRepostURI == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.green))
            action(post.viewerLikeURI == nil ? "heart" : "heart.fill", count: post.likeCount, label: post.viewerLikeURI == nil ? "Like" : "Unlike", action: like)
                .foregroundStyle(post.viewerLikeURI == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.pink))
            Button(action: quote) { Image(systemName: "quote.bubble") }.accessibilityLabel("Quote Post")
            Spacer()
            ShareLink(item: URL(string: "https://bsky.app/profile/\(post.author.did)/post/\(post.uri.split(separator: "/").last ?? "")")!) {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("Share Post")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private func action(_ image: String, count: Int, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) { Image(systemName: image); if count > 0 { Text(count, format: .number.notation(.compactName)) } }
        }
        .accessibilityLabel(label)
        .accessibilityValue(count == 0 ? "" : count.formatted())
    }
}
