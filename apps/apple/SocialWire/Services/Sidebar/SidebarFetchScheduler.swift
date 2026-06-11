import Foundation

/// Coordinates sidebar bootstrap vs reader content refresh policies.
enum SidebarFetchScheduler {
    /// Delay before background sidebar publication prefetch after bootstrap.
    static let prefetchDelaySeconds: TimeInterval = 8

    /// Skip full-sidebar unread refetch when bootstrap completed within this window.
    static let postBootstrapUnreadSkipSeconds: TimeInterval = 5

    static func shouldSkipUnreadRefresh(since bootstrapCompletedAt: Date?) -> Bool {
        guard let bootstrapCompletedAt else { return false }
        return Date().timeIntervalSince(bootstrapCompletedAt) < postBootstrapUnreadSkipSeconds
    }
}
