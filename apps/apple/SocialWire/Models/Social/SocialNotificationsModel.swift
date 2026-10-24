import Foundation
import Observation

@MainActor
@Observable
final class SocialNotificationsModel {
    @ObservationIgnored private var generation = UUID()
    private let client: SocialWireSocialClient
    @ObservationIgnored private var readTask: Task<Void, Never>?
    private(set) var notifications: [SocialNotification] = []
    private(set) var unreadCount = 0
    private(set) var isLoading = false
    private(set) var error: String?

    init(client: SocialWireSocialClient) { self.client = client }

    func reset() {
        generation = UUID()
        readTask?.cancel()
        readTask = nil
        notifications = []
        unreadCount = 0
        isLoading = false
        error = nil
    }

    func refresh() async {
        let current = generation
        readTask?.cancel()
        isLoading = true
        error = nil
        defer { if generation == current { isLoading = false } }
        do {
            async let page = client.notifications()
            async let count = client.unreadNotificationCount()
            let result = try await (page, count)
            guard generation == current else { return }
            notifications = result.0.items
            unreadCount = result.1
            scheduleLoadedBoundaryRead()
        } catch is CancellationError { } catch { if generation == current { self.error = error.localizedDescription } }
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
        let current = generation
        do {
            try await client.markNotificationsSeen(at: boundary)
            guard generation == current else { return }
            notifications = notifications.map { item in
                var copy = item
                if copy.indexedAt <= boundary { copy.isRead = true }
                return copy
            }
            unreadCount = notifications.filter { !$0.isRead }.count
        } catch { if generation == current { self.error = error.localizedDescription } }
    }
}
