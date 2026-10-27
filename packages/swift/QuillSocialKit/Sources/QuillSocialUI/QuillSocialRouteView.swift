#if os(iOS)
import ATProtoCore
import Feeds
import Navigation
import SwiftUI

struct QuillSocialRouteView: View {
    let route: Route

    @Environment(AppServices.self) private var services

    @ViewBuilder
    var body: some View {
        switch route {
        case .thread(let uri):
            PostThreadView(uri: uri, source: services.postThreadSource)
                .roundedNavigationTitle("Post")
        case .profile(let actor):
            ProfileView(actor: actor.description)
        case .feed(let uri):
            FeedRouteView(timeline: TimelineModel(
                source: services.feedTimelineSource(PinnedFeed(uri: uri, name: "Feed"))
            ))
            .roundedNavigationTitle("Feed")
        case .list(let uri):
            FeedRouteView(timeline: timeline(
                nsid: "app.bsky.feed.getListFeed", parameters: ["list": uri.description]
            ))
            .roundedNavigationTitle("List")
        case .hashtag(let topic):
            FeedRouteView(
                timeline: timeline(
                    nsid: "app.bsky.feed.searchPosts",
                    parameters: ["q": topic, "sort": "top"],
                    postsKey: "posts"
                ),
                stockTicker: CashtagTickerDetector.tickerTopic(in: topic)
            )
            .roundedNavigationTitle(topic.hasPrefix("$") ? "\(topic)" : "#\(topic)")
        case .conversation(let id):
            ConversationView(conversationID: id)
        case .likedBy(let uri):
            QuillSocialPeopleView(
                title: "Liked By", nsid: "app.bsky.feed.getLikes",
                parameters: ["uri": uri.description], collectionKey: "likes", actorKey: "actor"
            )
        case .repostedBy(let uri):
            QuillSocialPeopleView(
                title: "Reposted By", nsid: "app.bsky.feed.getRepostedBy",
                parameters: ["uri": uri.description], collectionKey: "repostedBy"
            )
        case .quotes(let uri):
            FeedRouteView(timeline: timeline(
                nsid: "app.bsky.feed.getQuotes", parameters: ["uri": uri.description], postsKey: "posts"
            ))
            .roundedNavigationTitle("Quotes")
        case .followers(let actor):
            QuillSocialPeopleView(
                title: "Followers", nsid: "app.bsky.graph.getFollowers",
                parameters: ["actor": actor.description], collectionKey: "followers"
            )
        case .following(let actor):
            QuillSocialPeopleView(
                title: "Following", nsid: "app.bsky.graph.getFollows",
                parameters: ["actor": actor.description], collectionKey: "follows"
            )
        case .labeler(let did):
            LabelerModerationView(did: did.description)
        case .settings:
            ProfileSettingsView()
        }
    }

    private func timeline(
        nsid: String, parameters: [String: String], postsKey: String? = nil
    ) -> TimelineModel {
        let request = services.appViewRequest
        return TimelineModel(source: ATProtoTimelineSource { paging in
            let data = try await request(nsid, parameters.merging(paging) { _, new in new })
            guard let postsKey else { return data }
            guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let posts = object.removeValue(forKey: postsKey) as? [[String: Any]] else {
                throw URLError(.cannotParseResponse)
            }
            object["feed"] = posts.map { ["post": $0] }
            return try JSONSerialization.data(withJSONObject: object)
        })
    }
}
#endif
