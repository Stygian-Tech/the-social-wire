#if os(iOS)
import Foundation
import Testing
@testable import QuillSocialUI

@Suite("Notification post content")
@MainActor
struct NotificationsModelTests {
    private let original = "at://did:plc:original/app.bsky.feed.post/original"
    private let authored = "at://did:plc:actor/app.bsky.feed.post/authored"

    @Test(arguments: ["like", "like-via-repost", "repost", "repost-via-repost"])
    func reactionsUseTheAffectedPost(reason: String) throws {
        let model = NotificationsModel()
        let notification = try item(reason: reason, uri: "at://did:plc:actor/app.bsky.feed.like/action",
                                    subject: nil, record: ["subject": ["uri": original]])
        #expect(model.postURI(for: notification) == original)
        #expect(model.contextPostURI(for: notification) == nil)
    }

    @Test(arguments: ["reply", "quote"])
    func authoredNotificationsRetainOriginalContext(reason: String) async throws {
        let model = NotificationsModel()
        let notification = try item(reason: reason, uri: authored, subject: original, record: ["text": "New content"])
        let probe = NotificationPreviewProbe(responses: [
            authored: [try thread(uri: authored, text: "New content", withImage: true)],
            original: [try thread(uri: original, text: "Original affected post")]
        ])
        await model.loadPostPreview(for: notification, using: { try await probe.request($0, $1) })
        #expect(model.postURI(for: notification) == authored)
        #expect(model.contextPostURI(for: notification) == original)
        #expect(model.postPreviews[authored]?.text == "New content")
        #expect(model.postPreviews[authored]?.images.first?.altText == "Accessible preview")
        #expect(model.postPreviews[original]?.text == "Original affected post")
        let calls = await probe.calls
        #expect(calls.map(\.method) == ["app.bsky.feed.getPostThread", "app.bsky.feed.getPostThread"])
        #expect(calls.allSatisfy { $0.parameters["depth"] == "0" && $0.parameters["parentHeight"] == "0" })
        #expect(calls.map { $0.parameters["uri"] } == [authored, original])
        await model.loadPostPreview(for: notification, using: { try await probe.request($0, $1) })
        #expect(await probe.calls.count == 2)
    }

    @Test("Record context works when reasonSubject is absent")
    func contextFallbacks() throws {
        let model = NotificationsModel()
        let reply = try item(reason: "reply", uri: authored, subject: nil,
                             record: ["reply": ["parent": ["uri": original]]])
        let quote = try item(reason: "quote", uri: authored, subject: nil,
                             record: ["embed": ["record": ["uri": original]]])
        let quoteWithMedia = try item(reason: "quote", uri: authored, subject: nil,
                                      record: ["embed": ["record": ["record": ["uri": original]]]])
        #expect(model.contextPostURI(for: reply) == original)
        #expect(model.contextPostURI(for: quote) == original)
        #expect(model.contextPostURI(for: quoteWithMedia) == original)
    }

    @Test("Reply and quote records identify their actual target before the notification thread subject")
    func canonicalContextOverridesThreadSubject() throws {
        let model = NotificationsModel()
        let threadRoot = "at://did:plc:original/app.bsky.feed.post/thread-root"
        let reply = try item(reason: "reply", uri: authored, subject: threadRoot,
                             record: ["reply": ["parent": ["uri": original]]])
        let quote = try item(reason: "quote", uri: authored, subject: threadRoot,
                             record: ["embed": ["record": ["uri": original]]])
        #expect(model.contextPostURI(for: reply) == original)
        #expect(model.contextPostURI(for: quote) == original)
    }

    @Test("Distinct replies and quotes remain separate while reactions to one post group")
    func groupingPreservesAuthoredContent() async throws {
        let model = NotificationsModel()
        let notifications = try [
            notificationObject(reason: "like", uri: authored + "-like-a", subject: original),
            notificationObject(reason: "like", uri: authored + "-like-b", subject: original),
            notificationObject(reason: "reply", uri: authored + "-reply-a", subject: original),
            notificationObject(reason: "reply", uri: authored + "-reply-b", subject: original),
            notificationObject(reason: "quote", uri: authored + "-quote-a", subject: original),
            notificationObject(reason: "quote", uri: authored + "-quote-b", subject: original)
        ]
        let data = try JSONSerialization.data(withJSONObject: ["notifications": notifications])
        await model.load { method, _ in
            #expect(method == "app.bsky.notification.listNotifications")
            return data
        }
        #expect(model.visibleGroups.count == 5)
        #expect(model.visibleGroups.first?.notifications.count == 2)
        #expect(model.visibleGroups.filter { $0.latest.reason == "quote" }.count == 2)
        #expect(model.visibleGroups.filter { $0.latest.reason == "reply" }.count == 2)
    }

    @Test("Unavailable or mismatched posts do not populate another URI and can retry")
    func unavailablePreviewRetriesWithoutPoisoningCache() async throws {
        let model = NotificationsModel()
        let notification = try item(reason: "like", uri: authored, subject: original)
        let probe = NotificationPreviewProbe(responses: [original: [
            try thread(uri: authored, text: "Wrong post"),
            try thread(uri: original, text: "Recovered original")
        ]])
        await model.loadPostPreview(for: notification, using: { try await probe.request($0, $1) })
        #expect(model.postPreviews.isEmpty)
        #expect(model.failedPostURIs.contains(original))
        await model.loadPostPreview(for: notification, using: { try await probe.request($0, $1) })
        #expect(model.postPreviews[original]?.text == "Recovered original")
        #expect(!model.failedPostURIs.contains(original))
    }

    @Test("Failure of a new reply does not hide the original affected post")
    func originalContextLoadsWhenAuthoredPostIsUnavailable() async throws {
        let model = NotificationsModel()
        let notification = try item(reason: "reply", uri: authored, subject: original)
        let probe = NotificationPreviewProbe(responses: [
            authored: [Data(#"{"thread":{"$type":"app.bsky.feed.defs#notFoundPost","notFound":true}}"#.utf8)],
            original: [try thread(uri: original, text: "Original remains visible")]
        ])
        await model.loadPostPreview(for: notification, using: { try await probe.request($0, $1) })
        #expect(model.failedPostURIs.contains(authored))
        #expect(model.postPreviews[original]?.text == "Original remains visible")
    }

    @Test("Profile and non-post subjects never request post hydration")
    func nonPostNotificationsDoNotHydrate() async throws {
        let model = NotificationsModel()
        let notification = try item(reason: "follow", uri: authored, subject: nil)
        let invalid = try item(reason: "like", uri: authored,
                               subject: "at://did:plc:original/app.bsky.actor.profile/self")
        let verification = try item(reason: "verified", uri: authored, subject: nil,
                                    record: ["subject": "did:plc:original"])
        let probe = NotificationPreviewProbe(responses: [:])
        await model.loadPostPreview(for: notification, using: { try await probe.request($0, $1) })
        await model.loadPostPreview(for: invalid, using: { try await probe.request($0, $1) })
        await model.loadPostPreview(for: verification, using: { try await probe.request($0, $1) })
        #expect(await probe.calls.isEmpty)
    }

    @Test("Canceled preview responses never populate visible content")
    func canceledPreviewDoesNotPublish() async throws {
        let model = NotificationsModel()
        let notification = try item(reason: "like", uri: authored, subject: original)
        let probe = SuspendedNotificationPreviewProbe()
        let loading = Task { await model.loadPostPreview(for: notification, using: { _, _ in await probe.load() }) }
        while !(await probe.started) { await Task.yield() }
        loading.cancel()
        await probe.finish(try thread(uri: original, text: "Canceled content"))
        await loading.value
        #expect(model.postPreviews.isEmpty)
        #expect(model.failedPostURIs.isEmpty)
    }

    private func item(reason: String, uri: String, subject: String?, record: [String: Any] = [:]) throws -> NotificationsModel.NotificationItem {
        let data = try JSONSerialization.data(withJSONObject: notificationObject(reason: reason, uri: uri, subject: subject, record: record))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(NotificationsModel.NotificationItem.self, from: data)
    }

    private func notificationObject(reason: String, uri: String, subject: String?, record: [String: Any] = [:]) throws -> [String: Any] {
        var notification: [String: Any] = [
            "uri": uri, "reason": reason, "record": record, "isRead": false,
            "author": ["did": "did:plc:actor", "handle": "actor.test", "displayName": "Actor"],
            "indexedAt": "2026-10-26T00:00:00Z"
        ]
        if let subject { notification["reasonSubject"] = subject }
        return notification
    }

    private func thread(uri: String, text: String, withImage: Bool = false) throws -> Data {
        var post: [String: Any] = [
            "uri": uri, "cid": "bafkreitestpost", "author": ["did": "did:plc:actor", "handle": "actor.test"],
            "record": ["$type": "app.bsky.feed.post", "text": text, "createdAt": "2026-10-26T00:00:00Z"],
            "indexedAt": "2026-10-26T00:00:00Z"
        ]
        if withImage {
            post["embed"] = ["$type": "app.bsky.embed.images#view", "images": [[
                "thumb": "https://example.test/thumb.jpg", "fullsize": "https://example.test/full.jpg", "alt": "Accessible preview"
            ]]]
        }
        return try JSONSerialization.data(withJSONObject: ["thread": ["post": post]])
    }
}

private actor NotificationPreviewProbe {
    struct Call: Sendable {
        let method: String
        let parameters: [String: String]
    }
    private(set) var calls: [Call] = []
    private var responses: [String: [Data]]

    init(responses: [String: [Data]]) { self.responses = responses }

    func request(_ method: String, _ parameters: [String: String]) throws -> Data {
        calls.append(Call(method: method, parameters: parameters))
        guard let uri = parameters["uri"], var available = responses[uri], !available.isEmpty else {
            throw URLError(.resourceUnavailable)
        }
        let result = available.removeFirst()
        responses[uri] = available
        return result
    }
}

private actor SuspendedNotificationPreviewProbe {
    private(set) var started = false
    private var continuation: CheckedContinuation<Data, Never>?

    func load() async -> Data {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func finish(_ data: Data) {
        continuation?.resume(returning: data)
        continuation = nil
    }
}
#endif
