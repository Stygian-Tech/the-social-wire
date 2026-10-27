import ATProtoCore
import Observation

@MainActor
@Observable
public final class PostThreadModel {
    public private(set) var thread: PostThread?
    public private(set) var isLoading = false
    public private(set) var didFail = false

    private let uri: ATURI
    private let source: any PostThreadSource

    public init(uri: ATURI, source: any PostThreadSource) {
        self.uri = uri
        self.source = source
    }

    public func load() async {
        guard thread == nil, !isLoading else { return }
        await fetch()
    }

    public func refresh() async {
        await fetch()
    }

    private func fetch() async {
        guard !isLoading else { return }
        isLoading = true
        didFail = false
        defer { isLoading = false }

        do {
            let result = try await source.thread(uri: uri)
            try Task.checkCancellation()
            thread = result
        } catch is CancellationError {
        } catch {
            didFail = true
        }
    }
}
