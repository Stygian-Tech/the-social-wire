import Foundation
import Observation

@MainActor
@Observable
final class SocialNotificationsModel {
    private let client: SocialWireSocialClient
    @ObservationIgnored private var readTask: Task<Void, Never>?
    private(set) var notifications: [SocialNotification] = []
    private(set) var unreadCount = 0
    private(set) var isLoading = false
    private(set) var error: String?

    init(client: SocialWireSocialClient) { self.client = client }

    func refresh() async {
        readTask?.cancel()
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            async let page = client.notifications()
            async let count = client.unreadNotificationCount()
            let result = try await (page, count)
            notifications = result.0.items
            unreadCount = result.1
            scheduleLoadedBoundaryRead()
        } catch is CancellationError { } catch { self.error = error.localizedDescription }
    }

    func markAllRead() async { await markRead(boundary: Date()) }

    func retryRead() { scheduleLoadedBoundaryRead() }

    private func scheduleLoadedBoundaryRead() {
        readTask?.cancel()
        guard let boundary = notifications.filter({ !$0.isRead }).map(\.indexedAt).max() else { return }
        readTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await self?.markRead(boundary: boundary)
            } catch { }
        }
    }

    private func markRead(boundary: Date) async {
        do {
            try await client.markNotificationsSeen(at: boundary)
            notifications = notifications.map { item in
                var copy = item
                if copy.indexedAt <= boundary { copy.isRead = true }
                return copy
            }
            unreadCount = notifications.filter { !$0.isRead }.count
        } catch { self.error = error.localizedDescription }
    }
}
