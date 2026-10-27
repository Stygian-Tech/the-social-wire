public protocol TimelineSource: Sendable {
    func timeline(cursor: String?, limit: Int) async throws -> TimelinePage
    /// Publishes usable posts before optional external metadata finishes resolving.
    func timeline(
        cursor: String?, limit: Int,
        onInitialPage: @escaping @Sendable (TimelinePage) async -> Void
    ) async throws -> TimelinePage
}

public extension TimelineSource {
    func timeline(
        cursor: String?, limit: Int,
        onInitialPage: @escaping @Sendable (TimelinePage) async -> Void
    ) async throws -> TimelinePage {
        try await timeline(cursor: cursor, limit: limit)
    }
}
