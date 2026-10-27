public protocol StorySource: Sendable {
    func stories() async throws -> [StoryFeedItem]
    /// Publishes snapshots as stories become available, then returns the complete rail.
    func stories(
        onUpdate: @escaping @Sendable ([StoryFeedItem]) async -> Void
    ) async throws -> [StoryFeedItem]
}

public extension StorySource {
    func stories(
        onUpdate: @escaping @Sendable ([StoryFeedItem]) async -> Void
    ) async throws -> [StoryFeedItem] {
        let items = try await stories()
        await onUpdate(items)
        return items
    }
}
