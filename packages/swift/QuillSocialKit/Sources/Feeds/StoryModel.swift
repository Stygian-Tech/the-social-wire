import Observation
import Foundation

@MainActor
@Observable
public final class StoryModel: StoryPublishingSource {
    private let source: any StorySource
    private(set) public var items: [StoryFeedItem] = []
    private(set) public var isLoading = false
    private(set) public var didFail = false

    public init(source: any StorySource) {
        self.source = source
    }

    public var hasRailContent: Bool { items.contains { $0.isCurrentUser || !$0.stories.isEmpty } }
    public var canPublish: Bool { source is any StoryPublishingSource }

    public func publishPhoto(data: Foundation.Data, mimeType: String) async throws -> String {
        guard let publisher = source as? any StoryPublishingSource else {
            throw Foundation.URLError(.unsupportedURL)
        }
        let uri = try await publisher.publishPhoto(data: data, mimeType: mimeType)
        // A refresh begun before createRecord can finish with a stale snapshot.
        // Wait for it, then always request a new repository snapshot.
        while isLoading {
            // Publishing succeeded: cancellation of a subsequent refresh must not
            // report publication failure and encourage a duplicate retry.
            if Task.isCancelled { return uri }
            try? await Task.sleep(for: .milliseconds(50))
        }
        await load()
        return uri
    }

    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let result = try await source.stories { [weak self] items in
                guard !Task.isCancelled else { return }
                await self?.publish(items)
            }
            try Task.checkCancellation()
            items = result
            didFail = false
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            didFail = true
        }
    }

    private func publish(_ items: [StoryFeedItem]) {
        // Keep the previous rail usable during a refresh. The completed result
        // removes expired/unfollowed stories after every source has been checked.
        let updatedIDs = Set(items.map(\.id))
        self.items = items + self.items.filter { !updatedIDs.contains($0.id) }
        didFail = false
    }
}
