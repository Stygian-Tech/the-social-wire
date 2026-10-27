#if os(iOS)
import Foundation
import Testing
@testable import QuillSocialUI

@MainActor
struct NotificationBadgeModelTests {
    @Test("Concurrent refreshes share the active request")
    func overlappingRefreshDoesNotDuplicateRequests() async {
        let request = NotificationBadgeRequestProbe()
        let model = NotificationBadgeModel(request: { _, _ in await request.load() })
        let refresh = Task { await model.refresh() }
        while request.continuation == nil { await Task.yield() }
        await model.refresh()
        #expect(request.calls == 1)
        request.finish(count: 8)
        await refresh.value
        #expect(model.unreadCount == 8)
    }

    @Test("A read acknowledgement cannot be overwritten by an earlier unread request")
    func clearFencesEarlierResponse() async {
        let request = NotificationBadgeRequestProbe()
        let model = NotificationBadgeModel(request: { _, _ in await request.load() })
        let refresh = Task { await model.refresh() }
        while request.continuation == nil { await Task.yield() }
        model.clear()
        request.finish(count: 8)
        await refresh.value
        #expect(model.unreadCount == 0)
    }

    @Test("Canceled foreground refreshes do not publish a stale badge")
    func cancellationDiscardsResponse() async {
        let request = NotificationBadgeRequestProbe()
        let model = NotificationBadgeModel(request: { _, _ in await request.load() })
        let refresh = Task { await model.refresh() }
        while request.continuation == nil { await Task.yield() }
        refresh.cancel()
        request.finish(count: 8)
        await refresh.value
        #expect(model.unreadCount == 0)
    }
}

@MainActor
private final class NotificationBadgeRequestProbe {
    var calls = 0
    var continuation: CheckedContinuation<Data, Never>?

    func load() async -> Data {
        calls += 1
        return await withCheckedContinuation { continuation = $0 }
    }

    func finish(count: Int) {
        continuation?.resume(returning: Data("{\"count\":\(count)}".utf8))
        continuation = nil
    }
}
#endif
