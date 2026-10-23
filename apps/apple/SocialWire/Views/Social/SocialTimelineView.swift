import SwiftUI

struct SocialTimelineView: View {
    @Bindable var model: SocialTimelineModel
    let navigate: (SocialRoute) -> Void
    let compose: (SocialPostReference?, SocialPostReference?, SocialPostReference?) -> Void

    var body: some View {
        List {
            ForEach(model.posts) { post in
                SocialPostRow(
                    post: post,
                    openProfile: { navigate(.profile(did: post.author.did)) },
                    openThread: { navigate(.post(uri: post.uri)) },
                    like: { Task { await model.toggleLike(post) } },
                    repost: { Task { await model.toggleRepost(post) } },
                    reply: { compose(post.replyRoot ?? .init(uri: post.uri, cid: post.cid), .init(uri: post.uri, cid: post.cid), nil) },
                    quote: { compose(nil, nil, .init(uri: post.uri, cid: post.cid)) }
                )
                .task { await model.loadMore(after: post.id) }
            }
            if model.isLoadingMore { ProgressView().frame(maxWidth: .infinity) }
        }
        .listStyle(.plain)
        .refreshable { await model.refresh() }
        .overlay {
            if model.isLoading && model.posts.isEmpty { ProgressView("Loading Timeline") }
            else if let error = model.error, model.posts.isEmpty { ContentUnavailableView("Timeline Unavailable", systemImage: "exclamationmark.triangle", description: Text(error)) }
            else if model.posts.isEmpty { ContentUnavailableView("No Posts", systemImage: "bubble.left.and.text.bubble.right") }
        }
        .task { if model.posts.isEmpty { await model.refresh() } }
    }
}
