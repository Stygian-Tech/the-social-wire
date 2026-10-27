#if os(iOS)
import Navigation
import ATProtoCore
import SwiftData
import SwiftUI

/// Quill's Social views embedded in the host's existing app navigation and session.
public struct QuillSocialWorkspace: View {
    @Environment(\.scenePhase) private var scenePhase
    private let model: QuillSocialModel
    private let navigation: QuillSocialNavigation
    private let destination: QuillSocialDestination
    private let accentColor: Color
    private let onShowSidebar: (() -> Void)?
    private let onShowNotifications: (() -> Void)?
    private let onShowSettings: (() -> Void)?

    public init(model: QuillSocialModel, navigation: QuillSocialNavigation,
                destination: QuillSocialDestination, accentColor: Color = .accentColor, onShowSidebar: (() -> Void)? = nil,
                onShowNotifications: (() -> Void)? = nil, onShowSettings: (() -> Void)? = nil) {
        self.model = model
        self.navigation = navigation
        self.destination = destination
        self.accentColor = accentColor
        self.onShowSidebar = onShowSidebar
        self.onShowNotifications = onShowNotifications
        self.onShowSettings = onShowSettings
    }

    public var body: some View {
        workspace(stack: navigation.stack(for: destination))
            .task { navigation.bind(viewerDID: model.viewerDID) }
            .task(id: scenePhase) {
                if scenePhase == .active {
                    async let badge: Void = model.refreshNotificationBadge()
                    async let profile: Void = model.services.currentProfile.load()
                    _ = await (badge, profile)
                }
            }
    }

    private func workspace(stack: RouteStack) -> some View {
        @Bindable var stack = stack
        return NavigationStack(path: $stack.path) {
            configured(root, stack: stack)
                .navigationDestination(for: Route.self) { route in
                    // Split-view navigation can host destinations outside the root's subtree.
                    configured(QuillSocialRouteView(route: route), stack: stack)
                }
                .toolbar {
                    if stack.path.isEmpty, destination != .notifications, let onShowNotifications {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(action: onShowNotifications) {
                                Image(systemName: model.unreadNotificationCount > 0 ? "bell.badge.fill" : "bell")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(model.unreadNotificationCount > 0 ? Color.red : accentColor, accentColor)
                            }
                            .accessibilityLabel("Notifications")
                            .accessibilityValue("\(model.unreadNotificationCount) Unread")
                            .accessibilityIdentifier("social-open-notifications")
                        }
                    }
                }
        }
        .tint(accentColor)
        .accentColor(accentColor)
    }

    private func configured<Content: View>(_ content: Content, stack: RouteStack) -> some View {
        AppThemeView(accentColor: accentColor) { content }
            .toolbar {
                if let onShowSidebar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Show Sidebar", systemImage: "sidebar.left", action: onShowSidebar)
                            .labelStyle(.iconOnly)
                            .accessibilityIdentifier("news-show-sidebar")
                    }
                }
                // Apply to pushed routes as well, even while profile data is unavailable.
                if let onShowSettings {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Account", systemImage: "person.crop.circle", action: onShowSettings)
                            .labelStyle(.iconOnly)
                            .accessibilityIdentifier("social-open-account")
                    }
                }
            }
            .environment(\.hostAccountSettings, onShowSettings)
            .environment(model.services)
            .environment(model.homeFeeds)
            .environment(model.pinnedFeeds)
            .environment(model.stories)
            .environment(model.threadPositions)
            .environment(\.routeNavigator, RouteNavigator(stack: stack, mode: .push))
            .modelContainer(model.settingsContainer)
    }

    @ViewBuilder private var root: some View {
        switch destination {
        case .timeline: HomeTimelineView()
        case .explore, .feeds: ExploreView()
        case .notifications: NotificationsView()
        case .messages: ChatView()
        case .bookmarks: QuillSocialBookmarksView()
        case .lists: QuillSocialListsView(configuration: model.configuration)
        }
    }
}
#endif
