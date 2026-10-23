import Foundation

@MainActor
final class SocialWireSocialClient {
    private static let appViewService = "did:web:api.bsky.app#bsky_appview"
    private static let chatService = "did:web:api.bsky.chat#bsky_chat"
    private let xrpc: XRPCClient
    private let publicationService: PublicationService

    init(xrpc: XRPCClient, publicationService: PublicationService) {
        self.xrpc = xrpc
        self.publicationService = publicationService
    }

    var currentViewerDID: String? { xrpc.currentViewerDID }

    func viewerDID() async throws -> String { try await xrpc.currentDID() }

    func timeline(cursor: String? = nil, feed: String? = nil) async throws -> SocialPage<SocialPost> {
        let method = feed == nil ? "app.bsky.feed.getTimeline" : "app.bsky.feed.getFeed"
        let response: SocialFeedResponse = try await appViewGet(method, query: [
            "limit": "50", "cursor": cursor, "feed": feed
        ])
        return SocialPage(items: response.feed.map(\.socialPost), cursor: response.cursor)
    }

    func listFeed(_ list: String, cursor: String? = nil) async throws -> SocialPage<SocialPost> {
        let response: SocialFeedResponse = try await appViewGet("app.bsky.feed.getListFeed", query: [
            "list": list, "limit": "50", "cursor": cursor
        ])
        return SocialPage(items: response.feed.map(\.socialPost), cursor: response.cursor)
    }

    func authorFeed(actor: String, cursor: String? = nil) async throws -> SocialPage<SocialPost> {
        let response: SocialFeedResponse = try await appViewGet("app.bsky.feed.getAuthorFeed", query: [
            "actor": actor, "limit": "50", "cursor": cursor, "filter": "posts_with_replies"
        ])
        return SocialPage(items: response.feed.map(\.socialPost), cursor: response.cursor)
    }

    func postThread(uri: String) async throws -> [SocialPost] {
        let response: SocialThreadResponse = try await appViewGet("app.bsky.feed.getPostThread", query: [
            "uri": uri, "depth": "6", "parentHeight": "8"
        ])
        return response.thread.flattenedPosts
    }

    func profile(actor: String) async throws -> SocialProfile {
        let response: SocialProfileDTO = try await appViewGet("app.bsky.actor.getProfile", query: ["actor": actor])
        return response.socialProfile
    }

    func searchActors(query: String, cursor: String? = nil) async throws -> SocialPage<SocialAuthor> {
        let response: SocialActorSearchResponse = try await appViewGet("app.bsky.actor.searchActors", query: [
            "q": query, "limit": "30", "cursor": cursor
        ])
        return SocialPage(items: response.actors.map(\.socialAuthor), cursor: response.cursor)
    }

    func searchPosts(query: String, cursor: String? = nil) async throws -> SocialPage<SocialPost> {
        let response: SocialPostSearchResponse = try await appViewGet("app.bsky.feed.searchPosts", query: [
            "q": query, "limit": "50", "cursor": cursor, "sort": "latest"
        ])
        return SocialPage(items: response.posts.map(\.socialPost), cursor: response.cursor)
    }

    func suggestedFeeds(query: String = "", cursor: String? = nil) async throws -> SocialPage<SocialFeedSummary> {
        let method = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "app.bsky.feed.getSuggestedFeeds" : "app.bsky.unspecced.getPopularFeedGenerators"
        let response: SocialFeedDirectoryResponse = try await appViewGet(method, query: [
            "query": query.isEmpty ? nil : query, "limit": "30", "cursor": cursor
        ])
        return SocialPage(items: response.feeds.map(\.socialFeed), cursor: response.cursor)
    }

    func lists(cursor: String? = nil) async throws -> SocialPage<SocialListSummary> {
        let response: SocialListResponse = try await appViewGet("app.bsky.graph.getLists", query: [
            "actor": try await xrpc.currentDID(), "limit": "30", "cursor": cursor
        ])
        return SocialPage(items: response.lists.map(\.socialList), cursor: response.cursor)
    }

    func createList(name: String, description: String) async throws {
        let record: [String: JSONValue] = [
            "$type": .string("app.bsky.graph.list"), "purpose": .string("app.bsky.graph.defs#curatelist"),
            "name": .string(name), "description": .string(description), "createdAt": .string(Date().formatted(.iso8601))
        ]
        _ = try await xrpc.createRecord(collection: "app.bsky.graph.list", record: record)
    }

    func updateList(_ list: SocialListSummary, name: String, description: String) async throws {
        guard let rkey = list.uri.split(separator: "/").last.map(String.init) else { throw SocialWireError.invalidURL }
        let record: [String: JSONValue] = [
            "$type": .string("app.bsky.graph.list"), "purpose": .string("app.bsky.graph.defs#curatelist"),
            "name": .string(name), "description": .string(description), "createdAt": .string(Date().formatted(.iso8601))
        ]
        try await xrpc.putRecord(collection: "app.bsky.graph.list", rkey: rkey, record: record)
    }

    func deleteList(_ list: SocialListSummary) async throws { try await deleteRecord(uri: list.uri, collection: "app.bsky.graph.list") }

    func addListMember(listURI: String, did: String) async throws {
        let record: [String: JSONValue] = [
            "$type": .string("app.bsky.graph.listitem"), "list": .string(listURI), "subject": .string(did),
            "createdAt": .string(Date().formatted(.iso8601))
        ]
        _ = try await xrpc.createRecord(collection: "app.bsky.graph.listitem", record: record)
    }

    func bookmarks(cursor: String? = nil) async throws -> SocialPage<SocialPost> {
        let response: SocialBookmarkResponse = try await appViewGet("app.bsky.bookmark.getBookmarks", query: [
            "limit": "50", "cursor": cursor
        ])
        return SocialPage(items: response.bookmarks.map(\.item.socialPost), cursor: response.cursor)
    }

    func notifications(cursor: String? = nil) async throws -> SocialPage<SocialNotification> {
        let response: SocialNotificationResponse = try await appViewGet("app.bsky.notification.listNotifications", query: [
            "limit": "50", "cursor": cursor
        ])
        return SocialPage(items: response.notifications.map(\.socialNotification), cursor: response.cursor)
    }

    func unreadNotificationCount() async throws -> Int {
        let response: SocialUnreadCountResponse = try await appViewGet("app.bsky.notification.getUnreadCount")
        return response.count
    }

    func markNotificationsSeen(at date: Date) async throws {
        let _: SocialEmptyResponse = try await xrpc.authorizedServiceProxyPost(
            method: "app.bsky.notification.updateSeen",
            service: Self.appViewService,
            body: SocialSeenRequest(seenAt: date.formatted(.iso8601)),
            expectedViewer: try await xrpc.currentDID()
        )
    }

    func conversations(cursor: String? = nil) async throws -> SocialPage<SocialConversation> {
        let response: SocialConversationResponse = try await chatGet("chat.bsky.convo.listConvos", query: [
            "limit": "50", "cursor": cursor
        ])
        return SocialPage(items: response.convos.map(\.socialConversation), cursor: response.cursor)
    }

    func messages(conversationID: String, cursor: String? = nil) async throws -> SocialPage<SocialMessage> {
        let response: SocialMessageResponse = try await chatGet("chat.bsky.convo.getMessages", query: [
            "convoId": conversationID, "limit": "50", "cursor": cursor
        ])
        return SocialPage(items: response.messages.compactMap(\.socialMessage), cursor: response.cursor)
    }

    func sendMessage(conversationID: String, text: String, replyTo: SocialMessageReference? = nil) async throws -> SocialMessage {
        let response: SocialMessageDTO = try await xrpc.authorizedServiceProxyPost(
            method: "chat.bsky.convo.sendMessage",
            service: Self.chatService,
            body: SocialSendMessageRequest(convoId: conversationID, message: .init(text: text, replyTo: replyTo)),
            expectedViewer: try await xrpc.currentDID()
        )
        guard let message = response.socialMessage else { throw SocialWireError.badResponse("The message response was invalid.") }
        return message
    }

    func markConversationRead(_ conversationID: String, messageID: String) async throws {
        let _: SocialConversationDTO = try await xrpc.authorizedServiceProxyPost(
            method: "chat.bsky.convo.updateRead",
            service: Self.chatService,
            body: SocialUpdateReadRequest(convoId: conversationID, messageId: messageID),
            expectedViewer: try await xrpc.currentDID()
        )
    }

    func toggleReaction(conversationID: String, message: SocialMessage, value: String, viewerDID: String) async throws -> SocialMessage {
        let removing = message.reactions.contains { $0.senderDID == viewerDID && $0.value == value }
        let response: SocialSingleMessageResponse = try await chatPost(
            removing ? "chat.bsky.convo.removeReaction" : "chat.bsky.convo.addReaction",
            body: SocialReactionRequest(convoId: conversationID, messageId: message.id, value: value)
        )
        guard let updated = response.message.socialMessage else { throw SocialWireError.badResponse("The reaction response was invalid.") }
        return updated
    }

    func deleteMessage(conversationID: String, messageID: String) async throws {
        let _: SocialEmptyResponse = try await chatPost("chat.bsky.convo.deleteMessageForSelf", body: SocialMessageActionRequest(convoId: conversationID, messageId: messageID))
    }

    func setConversationMuted(_ conversationID: String, muted: Bool) async throws -> SocialConversation {
        let response: SocialConversationDTO = try await chatPost(muted ? "chat.bsky.convo.muteConvo" : "chat.bsky.convo.unmuteConvo", body: SocialConversationActionRequest(convoId: conversationID))
        return response.socialConversation
    }

    func acceptConversation(_ conversationID: String) async throws {
        let _: SocialEmptyResponse = try await chatPost("chat.bsky.convo.acceptConvo", body: SocialConversationActionRequest(convoId: conversationID))
    }

    func leaveConversation(_ conversationID: String) async throws {
        let _: SocialEmptyResponse = try await chatPost("chat.bsky.convo.leaveConvo", body: SocialConversationActionRequest(convoId: conversationID))
    }

    func createPost(text: String, reply: SocialReplyReference? = nil, quote: SocialPostReference? = nil) async throws {
        if let reply {
            try await publicationService.createReply(text: text, root: reply.root, parent: reply.parent)
        } else {
            try await publicationService.createPost(text: text, quote: quote)
        }
    }

    func publishThread(_ segments: [SocialThreadDraftSegment], root: SocialPostReference?, parent: SocialPostReference?, expectedViewer: String, progress: @MainActor (Int, StrongRef) -> Void) async throws {
        var threadRoot = root.map { StrongRef(uri: $0.uri, cid: $0.cid) }
        var threadParent = parent.map { StrongRef(uri: $0.uri, cid: $0.cid) }
        for (index, segment) in segments.enumerated() {
            guard currentViewerDID == expectedViewer else { throw SocialWireError.badResponse("The Signed-In Account Changed.") }
            if let reference = segment.published {
                if threadRoot == nil { threadRoot = reference }
                threadParent = reference
                continue
            }
            let embed = try await imageEmbed(for: segment.attachments, expectedViewer: expectedViewer)
            let reference = try await publicationService.createPostReference(
                text: segment.text,
                recordKey: segment.recordKey, createdAt: segment.createdAt, expectedViewer: expectedViewer,
                replyRoot: threadRoot,
                replyParent: threadParent,
                quote: index == 0 ? segment.quote : nil,
                embed: embed
            )
            if threadRoot == nil { threadRoot = reference }
            threadParent = reference
            progress(index, reference)
        }
    }

    private func imageEmbed(for attachments: [SocialComposerAttachment], expectedViewer: String) async throws -> [String: JSONValue]? {
        guard !attachments.isEmpty else { return nil }
        var images: [JSONValue] = []
        for attachment in attachments {
            let blob = try await xrpc.uploadBlob(data: attachment.data, mimeType: attachment.mimeType, expectedViewer: expectedViewer)
            images.append(.object([
                "alt": .string(attachment.altText),
                "image": .object([
                    "$type": .string(blob.type),
                    "ref": .object(["$link": .string(blob.reference.link)]),
                    "mimeType": .string(blob.mimeType),
                    "size": .number(Double(blob.size))
                ])
            ]))
        }
        return ["$type": .string("app.bsky.embed.images"), "images": .array(images)]
    }

    func like(_ post: SocialPost) async throws -> String {
        try await publicationService.createLike(subject: .init(uri: post.uri, cid: post.cid))
    }

    func repost(_ post: SocialPost) async throws -> String {
        try await publicationService.createRepost(subject: .init(uri: post.uri, cid: post.cid))
    }

    func deleteRecord(uri: String, collection: String) async throws {
        guard let rkey = uri.split(separator: "/").last.map(String.init) else { throw SocialWireError.invalidURL }
        try await xrpc.deleteRecord(collection: collection, rkey: rkey)
    }

    func follow(did: String) async throws -> String {
        let record: [String: JSONValue] = [
            "$type": .string("app.bsky.graph.follow"),
            "subject": .string(did),
            "createdAt": .string(Date().formatted(.iso8601))
        ]
        return try await xrpc.createRecord(collection: "app.bsky.graph.follow", record: record)
    }

    private func appViewGet<T: Decodable>(_ method: String, query: [String: String?] = [:]) async throws -> T {
        try await xrpc.authorizedServiceProxyGet(method: method, service: Self.appViewService, query: query)
    }

    private func chatGet<T: Decodable>(_ method: String, query: [String: String?] = [:]) async throws -> T {
        try await xrpc.authorizedServiceProxyGet(method: method, service: Self.chatService, query: query)
    }

    private func chatPost<T: Decodable, Body: Encodable>(_ method: String, body: Body) async throws -> T {
        try await xrpc.authorizedServiceProxyPost(method: method, service: Self.chatService, body: body, expectedViewer: try await xrpc.currentDID())
    }
}

struct SocialReplyReference: Sendable {
    let root: StrongRef
    let parent: StrongRef
}

private struct SocialSeenRequest: Encodable { let seenAt: String }
private struct SocialUpdateReadRequest: Encodable { let convoId: String; let messageId: String }
private struct SocialSendMessageRequest: Encodable {
    let convoId: String
    let message: Message
    struct Message: Encodable {
        let text: String
        let replyTo: SocialMessageReference?
        enum CodingKeys: String, CodingKey { case text; case replyTo }
        init(text: String, replyTo: SocialMessageReference?) { self.text = text; self.replyTo = replyTo }
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(text, forKey: .text)
            if let replyTo {
                try container.encode(["id": replyTo.id, "rev": replyTo.revision ?? ""], forKey: .replyTo)
            }
        }
    }
}

private struct SocialEmptyResponse: Decodable {}
private struct SocialConversationActionRequest: Encodable { let convoId: String }
private struct SocialMessageActionRequest: Encodable { let convoId: String; let messageId: String }
private struct SocialReactionRequest: Encodable { let convoId: String; let messageId: String; let value: String }
