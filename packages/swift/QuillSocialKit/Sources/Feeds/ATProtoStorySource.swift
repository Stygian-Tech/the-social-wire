import Foundation

public struct ATProtoStorySource: StorySource, StoryPublishingSource {
    public typealias SessionDID = @Sendable () async throws -> String
    public typealias Request = @Sendable (_ parameters: [String: String]) async throws -> Data

    private let sessionDID: SessionDID
    private let profileRequest: Request
    private let followsRequest: Request
    private let recordsRequest: Request
    private let procedure: ATProtoPostActionSource.Procedure?
    private let blobUpload: ATProtoPostActionSource.BlobUpload?
    private let now: @Sendable () -> Date

    public init(
        sessionDID: @escaping SessionDID,
        profileRequest: @escaping Request,
        followsRequest: @escaping Request,
        recordsRequest: @escaping Request,
        procedure: ATProtoPostActionSource.Procedure? = nil,
        blobUpload: ATProtoPostActionSource.BlobUpload? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.sessionDID = sessionDID
        self.profileRequest = profileRequest
        self.followsRequest = followsRequest
        self.recordsRequest = recordsRequest
        self.now = now
        self.procedure = procedure
        self.blobUpload = blobUpload
    }

    public func publishPhoto(data: Data, mimeType: String) async throws -> String {
        guard let procedure, let blobUpload else { throw URLError(.unsupportedURL) }
        guard !data.isEmpty, data.count <= 2_000_000,
              ["image/jpeg", "image/png", "image/webp"].contains(mimeType) else {
            throw URLError(.cannotDecodeContentData)
        }
        let did = try await sessionDID()
        let uploaded = try await blobUpload(data, mimeType)
        // Preserve the server's complete blob object, including its CID and size.
        guard let response = try JSONSerialization.jsonObject(with: uploaded) as? [String: Any],
              let blob = response["blob"] as? [String: Any],
              blob["ref"] is [String: Any], blob["mimeType"] is String else {
            throw URLError(.cannotParseResponse)
        }
        let body = try JSONSerialization.data(withJSONObject: [
            "repo": did, "collection": "blue.flashes.story.post",
            "record": ["$type": "blue.flashes.story.post", "text": "",
                       "image": blob, "createdAt": now().ISO8601Format(),
                       "expiresInMinutes": 1440],
        ])
        let result = try await procedure("com.atproto.repo.createRecord", body)
        return try JSONDecoder().decode(CreatedRecord.self, from: result).uri
    }

    private struct CreatedRecord: Decodable { let uri: String }

    public func stories() async throws -> [StoryFeedItem] {
        try await stories { _ in }
    }

    public func stories(
        onUpdate: @escaping @Sendable ([StoryFeedItem]) async -> Void
    ) async throws -> [StoryFeedItem] {
        let did = try await sessionDID()
        async let profileData = profileRequest(["actor": did])
        async let currentStories = currentUserRecords(for: did)
        async let followedAuthors = follows(actor: did)

        let currentAuthor = try await JSONDecoder().decode(Profile.self, from: profileData).storyAuthor
        let currentItem = StoryFeedItem(
            author: currentAuthor,
            stories: await currentStories,
            isCurrentUser: true
        )
        try Task.checkCancellation()
        await onUpdate([currentItem])

        let authors = try await followedAuthors
        var seenDIDs: Set<String> = [did]
        let uniqueAuthors = authors.filter { seenDIDs.insert($0.did).inserted }
        let followedItems = await activeStoryItems(for: uniqueAuthors) { items in
            await onUpdate([currentItem] + items)
        }
        try Task.checkCancellation()
        return [currentItem] + followedItems
    }

    private func follows(actor: String) async throws -> [StoryAuthor] {
        var authors: [StoryAuthor] = []
        var cursor: String?
        var seenCursors: Set<String> = []

        repeat {
            try Task.checkCancellation()
            var parameters = ["actor": actor, "limit": "100"]
            if let cursor {
                parameters["cursor"] = cursor
            }
            let data = try await followsRequest(parameters)
            let response = try JSONDecoder().decode(FollowsResponse.self, from: data)
            authors.append(contentsOf: response.follows.map(\.storyAuthor))
            cursor = response.cursor
            if let cursor, !seenCursors.insert(cursor).inserted { break }
        } while cursor != nil

        return authors
    }

    private func activeStoryItems(
        for authors: [StoryAuthor],
        onUpdate: @escaping @Sendable ([StoryFeedItem]) async -> Void
    ) async -> [StoryFeedItem] {
        await withTaskGroup(of: StoryFeedItem?.self) { group in
            var nextAuthor = 0
            func enqueue(_ author: StoryAuthor) {
                group.addTask {
                    guard !Task.isCancelled,
                          let stories = try? await records(for: author.did),
                          !stories.isEmpty else { return nil }
                    return StoryFeedItem(author: author, stories: stories, isCurrentUser: false)
                }
            }

            for author in authors.prefix(8) {
                enqueue(author)
                nextAuthor += 1
            }

            var items: [StoryFeedItem] = []
            for await item in group {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    break
                }
                if nextAuthor < authors.count {
                    enqueue(authors[nextAuthor])
                    nextAuthor += 1
                }
                if let item {
                    items.append(item)
                    items.sort {
                        let leftDate = $0.stories.first?.createdAt ?? .distantPast
                        let rightDate = $1.stories.first?.createdAt ?? .distantPast
                        return leftDate == rightDate
                            ? $0.author.did < $1.author.did
                            : leftDate > rightDate
                    }
                    await onUpdate(items)
                }
            }
            return items
        }
    }

    private func currentUserRecords(for did: String) async -> [StoryRecord] {
        // A missing/unavailable story collection must not hide the creation entry.
        (try? await records(for: did)) ?? []
    }

    private func records(for did: String) async throws -> [StoryRecord] {
        let data = try await recordsRequest([
            "repo": did,
            "collection": "blue.flashes.story.post",
            "limit": "100",
            "reverse": "true",
        ])
        let response = try JSONDecoder().decode(RecordsResponse.self, from: data)
        let currentDate = now()

        return response.records.compactMap { record in
            guard
                let createdAt = Self.date(record.value.createdAt),
                let image = record.value.image,
                record.value.expiresInMinutes > 0
            else { return nil }

            let expiresAt = createdAt.addingTimeInterval(
                TimeInterval(record.value.expiresInMinutes) * 60
            )
            guard expiresAt > currentDate else { return nil }
            return StoryRecord(
                uri: record.uri,
                blobCID: image.reference.link,
                mimeType: image.mimeType,
                createdAt: createdAt,
                expiresAt: expiresAt
            )
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    private static func date(_ value: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value) {
            return date
        }
        return try? Date.ISO8601FormatStyle().parse(value)
    }
}

private extension ATProtoStorySource {
    struct Profile: Decodable {
        let did: String
        let handle: String
        let displayName: String?
        let avatar: URL?

        var storyAuthor: StoryAuthor {
            StoryAuthor(did: did, handle: handle, displayName: displayName, avatarURL: avatar)
        }
    }

    struct FollowsResponse: Decodable {
        let follows: [Profile]
        let cursor: String?
    }

    struct RecordsResponse: Decodable {
        let records: [Record]
    }

    struct Record: Decodable {
        let uri: String
        let value: Value
    }

    struct Value: Decodable {
        let createdAt: String
        let expiresInMinutes: Int
        let image: Blob?
    }

    struct Blob: Decodable {
        let reference: Link
        let mimeType: String

        private enum CodingKeys: String, CodingKey {
            case reference = "ref"
            case mimeType
        }
    }

    struct Link: Decodable {
        let link: String

        private enum CodingKeys: String, CodingKey {
            case link = "$link"
        }
    }
}
