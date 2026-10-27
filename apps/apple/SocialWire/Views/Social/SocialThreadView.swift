import SwiftUI

struct SocialThreadView: View {
    let uri: String
    let client: SocialWireSocialClient
    let navigate: (SocialRoute) -> Void
    let compose: (SocialPostReference?, SocialPostReference?, SocialPostReference?) -> Void
    @State private var posts: [SocialPost] = []
    @State private var error: String?

    var body: some View {
        List(posts) { post in
            SocialPostRow(post: post, openProfile: { navigate(.profile(did: post.author.did)) }, openThread: {},
                          like: { Task { _ = try? await client.like(post) } }, repost: { Task { _ = try? await client.repost(post) } },
                          reply: { compose(post.replyRoot ?? .init(uri: post.uri, cid: post.cid), .init(uri: post.uri, cid: post.cid), nil) },
                          quote: { compose(nil, nil, .init(uri: post.uri, cid: post.cid)) })
        }
        .listStyle(.plain)
        .navigationTitle("Thread")
        .overlay { if posts.isEmpty && error == nil { ProgressView() } else if let error { ContentUnavailableView("Thread Unavailable", systemImage: "exclamationmark.bubble", description: Text(error)) } }
        .task(id: uri) { do { posts = try await client.postThread(uri: uri) } catch { self.error = error.localizedDescription } }
    }
}
