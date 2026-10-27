import Feeds
import Foundation
import Testing

struct ATProtoStorySourceTests {
    @Test func unavailableOwnCollectionStillShowsCreationEntry() async throws {
        let source = ATProtoStorySource(
            sessionDID: { "did:plc:current" },
            profileRequest: { _ in Self.currentProfile },
            followsRequest: { _ in Data(#"{"follows":[]}"#.utf8) },
            recordsRequest: { _ in throw URLError(.cannotLoadFromNetwork) }
        )
        let items = try await source.stories()
        #expect(items.count == 1)
        #expect(items.first?.isCurrentUser == true)
        #expect(items.first?.stories.isEmpty == true)
    }

    @Test func currentUserPublishesBeforeFollowingListCompletes() async throws {
        let followsGate = StoryRequestGate()
        let (updates, continuation) = AsyncStream.makeStream(of: [StoryFeedItem].self)
        let source = ATProtoStorySource(
            sessionDID: { "did:plc:current" },
            profileRequest: { _ in Self.currentProfile },
            followsRequest: { _ in
                await followsGate.wait()
                return Data(#"{"follows":[]}"#.utf8)
            },
            recordsRequest: { _ in Self.activeRecords },
            now: { Self.currentDate }
        )
        let loading = Task {
            try await source.stories { continuation.yield($0) }
        }
        var iterator = updates.makeAsyncIterator()
        let earlyItems = try #require(await iterator.next())

        #expect(earlyItems.count == 1)
        #expect(earlyItems[0].isCurrentUser)
        #expect(earlyItems[0].stories.count == 1)
        await followsGate.open()
        #expect(try await loading.value == earlyItems)
        continuation.finish()
    }

    @Test func followedStoriesPublishWithoutWaitingForSlowAuthors() async throws {
        let slowGate = StoryRequestGate()
        let (updates, continuation) = AsyncStream.makeStream(of: [StoryFeedItem].self)
        let source = ATProtoStorySource(
            sessionDID: { "did:plc:current" },
            profileRequest: { _ in Self.currentProfile },
            followsRequest: { _ in
                Data(#"{"follows":[{"did":"did:plc:slow","handle":"slow.test"},{"did":"did:plc:fast","handle":"fast.test"}]}"#.utf8)
            },
            recordsRequest: { parameters in
                if parameters["repo"] == "did:plc:slow" {
                    await slowGate.wait()
                }
                return parameters["repo"] == "did:plc:current"
                    ? Data(#"{"records":[]}"#.utf8) : Self.activeRecords
            },
            now: { Self.currentDate }
        )
        let loading = Task {
            try await source.stories { continuation.yield($0) }
        }
        var iterator = updates.makeAsyncIterator()
        _ = await iterator.next()
        let earlyItems = try #require(await iterator.next())
        #expect(earlyItems.map(\.author.did) == ["did:plc:current", "did:plc:fast"])

        await slowGate.open()
        let finalItems = try await loading.value
        #expect(finalItems.map(\.author.did) == ["did:plc:current", "did:plc:fast", "did:plc:slow"])
        continuation.finish()
    }

    @Test func repeatedFollowingCursorAndDuplicateAuthorsDoNotRepeatRequests() async throws {
        let requestCounts = StoryRequestCounts()
        let source = ATProtoStorySource(
            sessionDID: { "did:plc:current" },
            profileRequest: { _ in Self.currentProfile },
            followsRequest: { _ in
                await requestCounts.countFollow()
                return Data(#"{"follows":[{"did":"did:plc:current","handle":"me.test"},{"did":"did:plc:active","handle":"active.test"}],"cursor":"same"}"#.utf8)
            },
            recordsRequest: { parameters in
                await requestCounts.countRecords(parameters["repo"] ?? "")
                return Self.activeRecords
            },
            now: { Self.currentDate }
        )

        let items = try await source.stories()
        #expect(items.map(\.author.did) == ["did:plc:current", "did:plc:active"])
        #expect(await requestCounts.followCount == 2)
        #expect(await requestCounts.recordDIDs.sorted() == ["did:plc:active", "did:plc:current"])
    }

    @Test func currentUserIsFirstAndOnlyActiveFollowedStoriesAreIncluded() async throws {
        let now = try #require(
            try? Date.ISO8601FormatStyle().parse("2026-09-22T12:00:00Z")
        )
        let source = ATProtoStorySource(
            sessionDID: { "did:plc:current" },
            profileRequest: { _ in
                Data(
                    #"{"did":"did:plc:current","handle":"me.test","displayName":"Me","avatar":"https://example.com/me.jpg"}"#.utf8
                )
            },
            followsRequest: { _ in
                Data(
                    #"{"follows":[{"did":"did:plc:active","handle":"active.test","displayName":"Active","avatar":"https://example.com/active.jpg"},{"did":"did:plc:expired","handle":"expired.test"}]}"#.utf8
                )
            },
            recordsRequest: { parameters in
                switch parameters["repo"] {
                case "did:plc:active":
                    Data(
                        #"{"records":[{"uri":"at://did:plc:active/blue.flashes.story.post/new","value":{"createdAt":"2026-09-22T11:00:00Z","expiresInMinutes":1440,"image":{"ref":{"$link":"bafkreiactive"},"mimeType":"image/jpeg"}}}]}"#.utf8
                    )
                case "did:plc:expired":
                    Data(
                        #"{"records":[{"uri":"at://did:plc:expired/blue.flashes.story.post/old","value":{"createdAt":"2026-09-20T11:00:00Z","expiresInMinutes":1440,"image":{"ref":{"$link":"bafkreiexpired"},"mimeType":"image/jpeg"}}}]}"#.utf8
                    )
                default:
                    Data(#"{"records":[]}"#.utf8)
                }
            },
            now: { now }
        )

        let items = try await source.stories()

        #expect(items.map(\.author.did) == ["did:plc:current", "did:plc:active"])
        #expect(items[0].isCurrentUser)
        #expect(items[0].stories.isEmpty)
        #expect(items[1].stories.count == 1)
        #expect(items[1].stories[0].blobCID == "bafkreiactive")
        #expect(items[1].stories[0].mimeType == "image/jpeg")
    }

    private static let currentProfile = Data(#"{"did":"did:plc:current","handle":"me.test"}"#.utf8)
    private static let currentDate = Date(timeIntervalSince1970: 1_790_078_400)
    private static let activeRecords = Data(
        #"{"records":[{"uri":"at://did:plc:active/blue.flashes.story.post/new","value":{"createdAt":"2026-09-22T11:00:00Z","expiresInMinutes":1440,"image":{"ref":{"$link":"bafkreiactive"},"mimeType":"image/jpeg"}}}]}"#.utf8
    )
}

private actor StoryRequestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private actor StoryRequestCounts {
    private(set) var followCount = 0
    private(set) var recordDIDs: [String] = []

    func countFollow() { followCount += 1 }
    func countRecords(_ did: String) { recordDIDs.append(did) }
}
