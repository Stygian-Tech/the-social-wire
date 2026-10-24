import SwiftUI

struct SocialPostRow: View {
    let post: SocialPost
    let openProfile: () -> Void
    let openThread: () -> Void
    let like: () -> Void
    let repost: () -> Void
    let reply: () -> Void
    let quote: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let repostedBy = post.repostedBy {
                Label("Reposted by \(repostedBy.preferredName)", systemImage: "arrow.2.squarepath")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 10) {
                Button(action: openProfile) { SocialAvatarView(url: post.author.avatar, name: post.author.preferredName) }.buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 5) {
                    Button(action: openProfile) {
                        HStack(spacing: 5) {
                            Text(post.author.preferredName).font(.headline).lineLimit(1)
                            Text("@\(post.author.handle)").foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(post.createdAt, format: .relative(presentation: .named)).foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                    }
                    .buttonStyle(.plain)
                    if let replyingTo = post.replyingTo {
                        Text("Replying to @\(replyingTo.handle)").font(.caption).foregroundStyle(.secondary)
                    }
                    Button(action: openThread) { Text(post.text).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain)
                    SocialPostMediaView(embed: post.embed)
                    SocialPostActionsView(post: post, like: like, repost: repost, reply: reply, quote: quote)
                }
            }
        }
        .padding(.vertical, 8)
        .contentShape(.rect)
    }
}
