#if os(iOS)
import Feeds
import Foundation
import Observation

@MainActor
@Observable
final class StorySeenStore {
    private static let storageKeyPrefix = "story.seenRecordURIs"

    private(set) var recordURIs: Set<String> = []
    private let defaults: UserDefaults
    private var storageKey: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func bind(viewerDID: String?) {
        let key = viewerDID.flatMap { $0.isEmpty ? nil : "\(Self.storageKeyPrefix).\($0)" }
        guard storageKey != key else { return }
        storageKey = key
        // The legacy shared key cannot be attributed to a particular viewer.
        recordURIs = Set(key.flatMap { defaults.stringArray(forKey: $0) } ?? [])
    }

    func hasSeen(_ story: StoryRecord) -> Bool {
        recordURIs.contains(story.uri)
    }

    func markSeen(_ story: StoryRecord) {
        guard let storageKey, recordURIs.insert(story.uri).inserted else { return }
        defaults.set(Array(recordURIs), forKey: storageKey)
    }
}

#endif
