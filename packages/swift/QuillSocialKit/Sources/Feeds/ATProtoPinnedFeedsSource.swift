import ATProtoCore
import Foundation

public struct ATProtoPinnedFeedsSource: PinnedFeedsSource {
    public typealias PreferencesRequest = @Sendable () async throws -> Data
    public typealias PreferencesUpdate = @Sendable (_ body: Data) async throws -> Void
    public typealias FeedRequest = @Sendable (_ uri: String) async throws -> Data

    private let preferencesRequest: PreferencesRequest
    private let preferencesUpdate: PreferencesUpdate?
    private let feedRequest: FeedRequest
    private let generatorRecordRequest: FeedRequest?

    public init(
        preferencesRequest: @escaping PreferencesRequest,
        preferencesUpdate: PreferencesUpdate? = nil,
        feedRequest: @escaping FeedRequest,
        generatorRecordRequest: FeedRequest? = nil
    ) {
        self.preferencesRequest = preferencesRequest
        self.preferencesUpdate = preferencesUpdate
        self.feedRequest = feedRequest
        self.generatorRecordRequest = generatorRecordRequest
    }

    public func pinnedFeeds() async throws -> [PinnedFeed] {
        try await pinnedFeeds(onInitialFeeds: { _ in })
    }

    public func pinnedFeeds(
        onInitialFeeds: @escaping @Sendable ([PinnedFeed]) async -> Void
    ) async throws -> [PinnedFeed] {
        let data = try await preferencesRequest()
        let response = try JSONDecoder().decode(PreferencesResponse.self, from: data)
        var seen = Set<String>()
        let initialFeeds = response.pinnedFeedURIs.compactMap { value -> PinnedFeed? in
            guard seen.insert(value).inserted,
                  let uri = try? ATURI(value),
                  uri.collection?.description == "app.bsky.feed.generator" else { return nil }
            return PinnedFeed(uri: uri, name: uri.recordKey?.description ?? "Feed")
        }
        try Task.checkCancellation()
        await onInitialFeeds(initialFeeds)
        try Task.checkCancellation()
        let feeds = await withTaskGroup(of: (Int, PinnedFeed).self) { group in
            var nextIndex = 0
            for index in 0..<min(4, initialFeeds.count) {
                group.addTask { (index, await resolve(initialFeeds[index])) }
                nextIndex += 1
            }
            var feeds = initialFeeds
            for await (index, feed) in group {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                feeds[index] = feed
                await onInitialFeeds(feeds)
                if nextIndex < initialFeeds.count {
                    let index = nextIndex
                    nextIndex += 1
                    group.addTask { (index, await resolve(initialFeeds[index])) }
                }
            }
            return feeds
        }
        try Task.checkCancellation()
        return feeds
    }

    private func resolve(_ feed: PinnedFeed) async -> PinnedFeed {
        if let view = try? await resolvedFeed(for: feed.uri.description),
           !view.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return PinnedFeed(uri: feed.uri, name: view.displayName, avatarURL: view.avatar)
        }
        // Generator records are public. Older OAuth sessions or an App View without
        // this method must not prevent the carousel from displaying their names.
        guard !Task.isCancelled, let generatorRecordRequest,
              let data = try? await generatorRecordRequest(feed.uri.description),
              let record = try? JSONDecoder().decode(GeneratorRecordResponse.self, from: data),
              !record.value.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return feed }
        return PinnedFeed(uri: feed.uri, name: record.value.displayName)
    }

    public func updatePinnedFeeds(_ feeds: [PinnedFeed]) async throws {
        guard let preferencesUpdate else { throw PinnedFeedsMutationUnsupported() }
        let data = try await preferencesRequest()
        let body = try Self.updatedPreferencesBody(
            from: data,
            pinnedFeedURIs: feeds.map { $0.uri.description }
        )
        try await preferencesUpdate(body)
    }

    private func resolvedFeed(for uri: String) async throws -> FeedView? {
        let data = try await feedRequest(uri)
        return try JSONDecoder().decode(FeedResponse.self, from: data).view
    }

    static func updatedPreferencesBody(from data: Data, pinnedFeedURIs: [String]) throws -> Data {
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var preferences = response["preferences"] as? [[String: Any]] else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid preferences"))
        }

        if let index = preferences.firstIndex(where: {
            $0["$type"] as? String == "app.bsky.actor.defs#savedFeedsPrefV2"
        }) {
            var preference = preferences[index]
            let items = preference["items"] as? [[String: Any]] ?? []
            let existingFeeds = items.reduce(into: [String: [String: Any]]()) { result, item in
                guard item["type"] as? String == "feed",
                      item["pinned"] as? Bool == true,
                      let value = item["value"] as? String else { return }
                result[value] = item
            }
            var replacements = pinnedFeedURIs.map { uri in
                existingFeeds[uri] ?? ["type": "feed", "value": uri, "pinned": true]
            }
            var updatedItems: [[String: Any]] = []
            for item in items {
                if item["type"] as? String == "feed", item["pinned"] as? Bool == true {
                    if !replacements.isEmpty {
                        updatedItems.append(replacements.removeFirst())
                    }
                } else {
                    updatedItems.append(item)
                }
            }
            updatedItems.append(contentsOf: replacements)
            preference["items"] = updatedItems
            preferences[index] = preference
        } else if let index = preferences.firstIndex(where: {
            $0["$type"] as? String == "app.bsky.actor.defs#savedFeedsPref"
        }) {
            preferences[index]["pinned"] = pinnedFeedURIs
        } else {
            preferences.append([
                "$type": "app.bsky.actor.defs#savedFeedsPrefV2",
                "items": pinnedFeedURIs.map { ["type": "feed", "value": $0, "pinned": true] },
            ])
        }

        return try JSONSerialization.data(withJSONObject: ["preferences": preferences])
    }
}

private extension ATProtoPinnedFeedsSource {
    struct PreferencesResponse: Decodable {
        let preferences: [Preference]

        var pinnedFeedURIs: [String] {
            if let current = preferences.first(where: {
                $0.type == "app.bsky.actor.defs#savedFeedsPrefV2"
            }) {
                return current.pinnedFeedURIs
            }
            return preferences.first(where: {
                $0.type == "app.bsky.actor.defs#savedFeedsPref"
            })?.pinnedFeedURIs ?? []
        }
    }

    struct Preference: Decodable {
        let type: String?
        let pinned: [String]?
        let items: [Item]?

        var pinnedFeedURIs: [String] {
            if type == "app.bsky.actor.defs#savedFeedsPrefV2" {
                return (items ?? []).filter { $0.pinned && $0.type == "feed" }.map(\.value)
            }
            if type == "app.bsky.actor.defs#savedFeedsPref" {
                return pinned ?? []
            }
            return []
        }

        private enum CodingKeys: String, CodingKey {
            case type = "$type"
            case pinned
            case items
        }
    }

    struct Item: Decodable {
        let type: String
        let value: String
        let pinned: Bool
    }

    struct FeedResponse: Decodable {
        let view: FeedView
    }

    struct FeedView: Decodable {
        let displayName: String
        let avatar: URL?
    }

    struct GeneratorRecordResponse: Decodable {
        let value: GeneratorRecord
    }

    struct GeneratorRecord: Decodable {
        let displayName: String
    }
}
