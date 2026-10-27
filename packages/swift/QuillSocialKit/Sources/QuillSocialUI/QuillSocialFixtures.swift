#if os(iOS) && DEBUG
import Foundation

/// Offline content rendered through the production Quill models and views.
public enum QuillSocialFixtures {
    private static let viewer = "did:plc:fixtureviewer"
    private static let author = "did:plc:fixtureauthor"
    private static let reposter = "did:plc:fixturereposter"
    private static let feedURI = "at://did:plc:fixtureauthor/app.bsky.feed.generator/fixture"
    private static let rootURI = "at://did:plc:fixtureauthor/app.bsky.feed.post/root"
    private static let replyURI = "at://did:plc:fixtureauthor/app.bsky.feed.post/reply"

    @MainActor
    public static func model() throws -> QuillSocialModel {
        let configuration = QuillSocialConfiguration(
            viewerDID: viewer,
            appViewRequest: request,
            appViewProcedure: procedure,
            chatRequest: request,
            chatProcedure: procedure,
            pdsRequest: request,
            pdsProcedure: procedure,
            publicPDSRequest: { repo, method, parameters in
                var parameters = parameters
                parameters["repo"] = repo
                return try await request(method, parameters)
            },
            uploadBlob: { data, mimeType in
                try json(["blob": ["$type": "blob", "ref": ["$link": "bafkreifixtureimage"],
                                   "mimeType": mimeType, "size": data.count]])
            }
        )
        return try QuillSocialModel(configuration: configuration, inMemorySettings: true)
    }

    private static func request(_ method: String, _ parameters: [String: String]) async throws -> Data {
        switch method {
        case "app.bsky.actor.getPreferences":
            return try json(["preferences": [["$type": "app.bsky.actor.defs#savedFeedsPrefV2", "items": [
                ["id": "fixture-feed", "type": "feed", "value": feedURI, "pinned": true]
            ]]]])
        case "app.bsky.feed.getTimeline", "app.bsky.feed.getFeed", "app.bsky.feed.getListFeed", "app.bsky.feed.getAuthorFeed":
            guard parameters["cursor"] == nil else { return try json(["feed": []]) }
            let root = post(id: "root", text: "Quill Fixture Root", time: 0)
            let reply = post(id: "reply", text: "Quill Fixture Reply", time: 1, parent: "root")
            let repost = post(id: "reposted", text: "Quill Fixture Reposted Post", time: 2)
            let own = post(id: "own", text: "Quill Fixture Own Post", time: 3, authorDID: viewer)
            return try json(["feed": [
                ["post": root],
                ["post": reply, "reply": ["root": root, "parent": root]],
                ["post": repost, "reason": ["$type": "app.bsky.feed.defs#reasonRepost",
                                             "by": profile(did: reposter), "indexedAt": timestamp(offset: 2)]],
                ["post": own]
            ]])
        case "app.bsky.feed.getPostThread":
            let requested = parameters["uri"] ?? rootURI
            let root = post(id: "root", text: "Quill Fixture Root", time: 0)
            let reply = post(id: "reply", text: "Quill Fixture Reply", time: 1, parent: "root")
            let nested = post(id: "nested", text: "Quill Fixture Nested Reply", time: 2, parent: "reply")
            if requested.hasSuffix("/quote") {
                return try json(["thread": ["post": post(id: "quote", text: "Quill Fixture Quote", time: 3), "replies": []]])
            }
            if requested.hasSuffix("/own") {
                return try json(["thread": ["post": post(id: "own", text: "Quill Fixture Own Post", time: 3, authorDID: viewer), "replies": []]])
            }
            if requested == replyURI {
                return try json(["thread": ["post": reply, "parent": ["post": root],
                                            "replies": [["post": nested, "replies": []]]]])
            }
            if requested.hasSuffix("/reposted") {
                return try json(["thread": ["post": post(id: "reposted", text: "Quill Fixture Reposted Post", time: 2), "replies": []]])
            }
            return try json(["thread": ["post": root, "replies": [
                ["post": reply, "replies": [["post": nested, "replies": []]]]
            ]]])
        case "app.bsky.actor.getProfile":
            return try json(profile(did: parameters["actor"] ?? viewer))
        case "app.bsky.actor.searchActors", "app.bsky.actor.searchActorsTypeahead":
            return try json(["actors": [profile(did: author)]])
        case "app.bsky.graph.getFollows":
            return try json(["subject": profile(did: viewer), "follows": [profile(did: author)]])
        case "app.bsky.feed.getFeedGenerator":
            return try json(["view": feed(), "isOnline": true, "isValid": true])
        case "app.bsky.feed.getFeedGenerators", "app.bsky.feed.getSuggestedFeeds", "app.bsky.unspecced.getPopularFeedGenerators":
            return try json(["feeds": [feed()]])
        case "app.bsky.feed.searchPosts":
            return try json(["posts": [post(id: "root", text: "Quill Fixture Root", time: 0)]])
        case "app.bsky.notification.listNotifications":
            return try json(["notifications": [
                notification(reason: "like", uri: "at://\(reposter)/app.bsky.feed.like/fixture",
                             record: ["$type": "app.bsky.feed.like", "subject": ["uri": rootURI, "cid": "bafkreifixtureroot"]]),
                notification(reason: "like", uri: "at://\(author)/app.bsky.feed.like/fixture-second",
                             record: ["$type": "app.bsky.feed.like", "subject": ["uri": rootURI, "cid": "bafkreifixtureroot"]],
                             authorDID: author),
                notification(reason: "repost", uri: "at://\(reposter)/app.bsky.feed.repost/fixture",
                             record: ["$type": "app.bsky.feed.repost", "subject": ["uri": rootURI, "cid": "bafkreifixtureroot"]]),
                notification(reason: "reply", uri: replyURI,
                             record: ["$type": "app.bsky.feed.post", "text": "Quill Fixture Reply",
                                      "reply": ["parent": ["uri": rootURI, "cid": "bafkreifixtureroot"],
                                                "root": ["uri": rootURI, "cid": "bafkreifixtureroot"]]]),
                notification(reason: "quote", uri: "at://\(author)/app.bsky.feed.post/quote",
                             record: ["$type": "app.bsky.feed.post", "text": "Quill Fixture Quote",
                                      "embed": ["$type": "app.bsky.embed.record", "record": ["uri": rootURI, "cid": "bafkreifixtureroot"]]])
            ]])
        case "app.bsky.notification.getUnreadCount":
            return try json(["count": 0])
        case "app.bsky.labeler.getServices":
            return try json(["views": []])
        case "app.bsky.bookmark.getBookmarks":
            return try json(["bookmarks": []])
        case "app.bsky.graph.getLists":
            return try json(["lists": []])
        case "chat.bsky.convo.listConvos":
            return try json(["convos": []])
        case "com.atproto.repo.listRecords":
            guard parameters["collection"] == "blue.flashes.story.post" else { return try json(["records": []]) }
            let did = parameters["repo"] ?? viewer
            return try json(["records": [[
                "uri": "at://\(did)/blue.flashes.story.post/fixture", "cid": "bafkreifixturestory",
                "value": ["$type": "blue.flashes.story.post", "text": "Fixture Story",
                          "createdAt": timestamp(offset: 0), "expiresInMinutes": 1440,
                          "image": ["$type": "blob", "ref": ["$link": "bafkreifixtureimage"],
                                    "mimeType": "image/jpeg", "size": 1]]
            ]]])
        default:
            throw URLError(.unsupportedURL)
        }
    }

    private static func procedure(_ method: String, _ body: Data) async throws -> Data {
        if method == "com.atproto.repo.createRecord" || method == "com.atproto.repo.putRecord" {
            let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            let collection = payload?["collection"] as? String ?? "app.bsky.feed.post"
            return try json(["uri": "at://\(viewer)/\(collection)/fixture-created", "cid": "bafkreifixturecreated"])
        }
        switch method {
        case "com.atproto.repo.deleteRecord", "app.bsky.actor.putPreferences", "app.bsky.notification.updateSeen",
             "app.bsky.bookmark.createBookmark", "app.bsky.bookmark.deleteBookmark":
            return try json([:])
        default:
            throw URLError(.unsupportedURL)
        }
    }

    private static func notification(reason: String, uri: String, record: [String: Any], authorDID: String? = nil) -> [String: Any] {
        var record = record
        record["createdAt"] = timestamp(offset: 3)
        return ["uri": uri, "cid": "bafkreifixturenotification",
         "author": profile(did: authorDID ?? (["like", "repost"].contains(reason) ? reposter : author)),
         "reason": reason, "reasonSubject": rootURI, "record": record,
         "isRead": true, "indexedAt": timestamp(offset: 3)]
    }

    private static func profile(did: String) -> [String: Any] {
        ["did": did,
         "handle": did == viewer ? "viewer.fixture.test" : did == reposter ? "reposter.fixture.test" : "fixture.test",
         "displayName": did == viewer ? "Fixture Viewer" : did == reposter ? "Fixture Reposter" : "Fixture Author",
         "description": "Offline Quill Social Fixture", "followersCount": 12, "followsCount": 8,
         "postsCount": 3, "viewer": [:], "labels": []]
    }

    private static func post(id: String, text: String, time: Int, parent: String? = nil,
                             authorDID: String = author) -> [String: Any] {
        var record: [String: Any] = ["$type": "app.bsky.feed.post", "text": text, "createdAt": timestamp(offset: time)]
        if let parent {
            record["reply"] = ["root": ["uri": rootURI, "cid": "bafkreifixtureroot"],
                               "parent": ["uri": "at://\(author)/app.bsky.feed.post/\(parent)", "cid": "bafkreifixture\(parent)"]]
        }
        return ["uri": "at://\(authorDID)/app.bsky.feed.post/\(id)", "cid": "bafkreifixture\(id)",
                "author": profile(did: authorDID), "record": record, "indexedAt": timestamp(offset: time),
                "replyCount": 2, "repostCount": 4, "likeCount": 8, "quoteCount": 1, "viewer": [:], "labels": []]
    }

    private static func feed() -> [String: Any] {
        ["uri": feedURI, "cid": "bafkreifixturefeed", "did": author, "creator": profile(did: author),
         "displayName": "Fixture Feed", "description": "An Offline Pinned Feed", "likeCount": 2,
         "indexedAt": timestamp(offset: 0)]
    }

    private static func timestamp(offset: Int) -> String {
        Date().addingTimeInterval(-300 + Double(offset)).ISO8601Format()
    }

    private static func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
#endif
