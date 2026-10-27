#if os(iOS)
import Foundation
import Observation

@MainActor
@Observable
final class NotificationBadgeModel {
    private(set) var unreadCount = 0

    private var isRefreshing = false
    private var revision = 0
    private let request: AppServices.AppViewRequest

    init(request: @escaping AppServices.AppViewRequest) {
        self.request = request
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let requestRevision = revision
        defer { isRefreshing = false }
        guard let data = try? await request("app.bsky.notification.getUnreadCount", [:]),
              !Task.isCancelled, requestRevision == revision,
              let response = try? JSONDecoder().decode(Response.self, from: data) else { return }
        unreadCount = max(0, response.count)
    }

    func clear() {
        revision += 1
        unreadCount = 0
    }
}

private extension NotificationBadgeModel {
    struct Response: Decodable {
        let count: Int
    }
}

#endif
