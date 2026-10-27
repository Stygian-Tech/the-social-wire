#if os(iOS)
import Foundation
import ATProtoCore
import Feeds
import Observation

@MainActor
@Observable
final class NotificationsModel {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case mentions = "Mentions"

        var id: Self { self }
    }

    struct NotificationItem: Decodable, Identifiable, Sendable, Equatable {
        struct Author: Decodable, Sendable, Equatable {
            let did: String
            let handle: String
            let displayName: String?
            let avatar: URL?
        }

        struct Record: Decodable, Sendable, Equatable {
            struct Reference: Decodable, Sendable, Equatable {
                let uri: String
            }
            struct Reply: Decodable, Sendable, Equatable {
                let parent: Reference?
            }
            struct Embed: Decodable, Sendable, Equatable {
                struct EmbeddedRecord: Decodable, Sendable, Equatable {
                    let uri: String?
                    let record: Reference?
                }
                let record: EmbeddedRecord?
            }

            let text: String?
            let subject: Reference?
            let reply: Reply?
            let embed: Embed?

            private enum CodingKeys: String, CodingKey { case text, subject, reply, embed }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                text = try container.decodeIfPresent(String.self, forKey: .text)
                // Notifications carry many record lexicons. For example verification
                // subjects are DIDs, whereas reaction subjects are strong references.
                subject = try? container.decode(Reference.self, forKey: .subject)
                reply = try? container.decode(Reply.self, forKey: .reply)
                embed = try? container.decode(Embed.self, forKey: .embed)
            }
        }

        let uri: String
        let author: Author
        let reason: String
        let reasonSubject: String?
        let record: Record
        var isRead: Bool
        let indexedAt: Date

        var id: String { "\(reason):\(uri)" }
    }

    struct NotificationGroup: Identifiable, Equatable {
        let key: String
        var notifications: [NotificationItem]

        var id: String { key }
        var latest: NotificationItem { notifications[0] }
        var isRead: Bool { notifications.allSatisfy(\.isRead) }
        var authors: [NotificationItem.Author] {
            var seen: Set<String> = []
            return notifications.map(\.author).filter { seen.insert($0.did).inserted }
        }
    }

    var filter: Filter = .all
    private(set) var notifications: [NotificationItem] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var didFail = false
    private(set) var readErrorMessage: String?
    private(set) var postPreviews: [String: TimelinePost] = [:]
    private(set) var failedPostURIs: Set<String> = []

    private var cursor: String?
    private var loadingPostURIs: Set<String> = []

    var visibleNotifications: [NotificationItem] {
        switch filter {
        case .all:
            notifications
        case .mentions:
            notifications.filter { $0.reason == "mention" }
        }
    }

    var visibleGroups: [NotificationGroup] {
        var order: [String] = []
        var grouped: [String: [NotificationItem]] = [:]
        for notification in visibleNotifications {
            let key = groupKey(for: notification)
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(notification)
        }
        return order.compactMap { key in
            grouped[key].map { NotificationGroup(key: key, notifications: $0) }
        }
    }

    func load(using request: @escaping AppServices.AppViewRequest) async {
        guard notifications.isEmpty, !isLoading else { return }
        await fetch(replacing: true, using: request)
    }

    func refresh(using request: @escaping AppServices.AppViewRequest) async {
        await fetch(replacing: true, using: request)
    }

    @discardableResult
    func refreshAndMarkPreviouslyLoadedRead(
        using request: @escaping AppServices.AppViewRequest,
        procedure: @escaping AppServices.AppViewProcedure
    ) async -> Bool {
        let previousUnreadDate = notifications
            .filter { !$0.isRead }
            .map(\.indexedAt)
            .max()
        guard await fetch(replacing: true, using: request) else { return false }
        guard let previousUnreadDate else { return true }
        return await markRead(through: previousUnreadDate, using: procedure)
    }

    func loadMore(
        after group: NotificationGroup,
        using request: @escaping AppServices.AppViewRequest
    ) async {
        guard group.id == visibleGroups.last?.id,
              cursor != nil,
              !isLoadingMore else { return }
        await fetch(replacing: false, using: request)
    }

    @discardableResult
    func markRead(
        through date: Date,
        using procedure: @escaping AppServices.AppViewProcedure
    ) async -> Bool {
        let previous = notifications
        for index in notifications.indices where notifications[index].indexedAt <= date {
            notifications[index].isRead = true
        }
        readErrorMessage = nil

        do {
            let body = try JSONEncoder.notificationEncoder.encode(UpdateSeenRequest(seenAt: date))
            _ = try await procedure("app.bsky.notification.updateSeen", body)
            return true
        } catch {
            notifications = previous
            readErrorMessage = "The Social Wire couldn’t mark notifications as read."
            return false
        }
    }

    @discardableResult
    func markAllRead(
        at seenAt: Date = .now,
        using procedure: @escaping AppServices.AppViewProcedure
    ) async -> Bool {
        guard !notifications.isEmpty else { return true }
        return await markRead(through: seenAt, using: procedure)
    }

    func dismissReadError() {
        readErrorMessage = nil
    }

    func loadPostPreview(
        for notification: NotificationItem,
        using request: @escaping AppServices.AppViewRequest
    ) async {
        if let uri = postURI(for: notification) {
            await loadPost(uri: uri, using: request)
        }
        if let uri = contextPostURI(for: notification) {
            await loadPost(uri: uri, using: request)
        }
    }

    private func loadPost(uri: String, using request: @escaping AppServices.AppViewRequest) async {
        guard !Task.isCancelled, postPreviews[uri] == nil, loadingPostURIs.insert(uri).inserted else { return }
        defer { loadingPostURIs.remove(uri) }
        do {
            // Shallow authenticated threads work with existing sessions that predate
            // the getPosts grant, while retaining the viewer's App View moderation context.
            let source = ATProtoPostThreadSource { parameters in
                var parameters = parameters
                parameters["depth"] = "0"
                parameters["parentHeight"] = "0"
                return try await request("app.bsky.feed.getPostThread", parameters)
            }
            let thread = try await source.thread(uri: ATURI(uri))
            try Task.checkCancellation()
            guard let post = thread.entries.first(where: { $0.isFocused && $0.post.uri == uri })?.post else {
                failedPostURIs.insert(uri)
                return
            }
            postPreviews[uri] = post
            failedPostURIs.remove(uri)
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            failedPostURIs.insert(uri)
        }
    }

    /// Reactions open their subject; authored notifications open the new post.
    func postURI(for notification: NotificationItem) -> String? {
        let candidate: String?
        switch notification.reason {
        case "like", "like-via-repost", "repost", "repost-via-repost":
            candidate = notification.reasonSubject ?? notification.record.subject?.uri
        case "mention", "reply", "quote", "subscribed-post":
            candidate = notification.uri
        default:
            candidate = nil
        }
        return validPostURI(candidate)
    }

    /// Replies and quotes retain the original affected post alongside the new content.
    func contextPostURI(for notification: NotificationItem) -> String? {
        let candidate: String?
        switch notification.reason {
        case "reply":
            candidate = notification.record.reply?.parent?.uri ?? postPreviews[notification.uri]?.replyParentURI
                ?? notification.reasonSubject
        case "quote":
            candidate = notification.record.embed?.record?.uri ?? notification.record.embed?.record?.record?.uri
                ?? postPreviews[notification.uri]?.quote?.uri ?? notification.reasonSubject
        default:
            candidate = nil
        }
        guard candidate != postURI(for: notification) else { return nil }
        return validPostURI(candidate)
    }

    private func validPostURI(_ value: String?) -> String? {
        guard let value, let uri = try? ATURI(value),
              uri.collection?.description == "app.bsky.feed.post", uri.recordKey != nil else { return nil }
        return value
    }

    @discardableResult
    private func fetch(
        replacing: Bool,
        using request: @escaping AppServices.AppViewRequest
    ) async -> Bool {
        if replacing {
            isLoading = true
        } else {
            isLoadingMore = true
        }
        didFail = false
        defer {
            isLoading = false
            isLoadingMore = false
        }

        do {
            var parameters = ["limit": "50"]
            if !replacing, let cursor {
                parameters["cursor"] = cursor
            }
            let data = try await request("app.bsky.notification.listNotifications", parameters)
            let response = try Self.decoder.decode(Response.self, from: data)
            notifications = replacing ? response.notifications : notifications + response.notifications
            cursor = response.cursor
            return true
        } catch {
            didFail = true
            return false
        }
    }

    private func groupKey(for notification: NotificationItem) -> String {
        if ["reply", "quote", "mention", "subscribed-post"].contains(notification.reason) {
            return notification.id
        }
        return "\(notification.reason)|\(postURI(for: notification) ?? notification.reasonSubject ?? notification.reason)"
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(value, strategy: .iso8601) {
                return date
            }
            let strategy = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            return try strategy.parse(value)
        }
        return decoder
    }
}

private extension NotificationsModel {
    struct Response: Decodable {
        let cursor: String?
        let notifications: [NotificationItem]
    }

    struct UpdateSeenRequest: Encodable {
        let seenAt: Date
    }
}

private extension JSONEncoder {
    static var notificationEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

#endif
