#if os(iOS)
import ATProtoCore
import SwiftUI

struct NotificationsView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.routeNavigator) private var navigator
    @State private var model = NotificationsModel()
    @State private var actorGroup: NotificationsModel.NotificationGroup?

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            Picker("Notification Filter", selection: $model.filter) {
                ForEach(NotificationsModel.Filter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 6)

            Divider()

            notificationList
        }
        .roundedNavigationTitle("Notifications", inlineTitleFont: .body.weight(.semibold))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Mark All As Read", systemImage: "checkmark.circle") {
                    Task {
                        if await model.markAllRead(using: services.appViewProcedure) {
                            services.notificationBadge.clear()
                        }
                    }
                }
                .disabled(!model.notifications.contains { !$0.isRead })
            }
        }
        .sensoryFeedback(.selection, trigger: model.filter)
        .sensoryFeedback(.success, trigger: model.notifications.filter(\.isRead).count)
        .alert("Couldn’t Mark Notifications As Read", isPresented: readErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.readErrorMessage ?? "Please try again.")
        }
        .sheet(item: $actorGroup) { group in
            NotificationActorsView(authors: group.authors) { author in
                actorGroup = nil
                guard let actor = try? ActorIdentifier(author.did) else { return }
                navigator?(.profile(actor))
            }
        }
        .sensoryFeedback(.selection, trigger: actorGroup?.id)
        .task {
            await model.load(using: services.appViewRequest)
        }
    }

    @ViewBuilder
    private var notificationList: some View {
        if model.notifications.isEmpty, model.isLoading {
            ProgressView("Loading Notifications")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.notifications.isEmpty, model.didFail {
            ContentUnavailableView {
                Label("Notifications Unavailable", systemImage: "wifi.exclamationmark")
            } description: {
                Text("The Social Wire couldn’t load your notifications.")
            } actions: {
                Button("Try Again") {
                    Task { await refreshNotifications() }
                }
                .buttonStyle(.borderedProminent)
            }
        } else if model.visibleNotifications.isEmpty {
            ContentUnavailableView(
                model.filter == .mentions ? "No Mentions" : "No Notifications",
                systemImage: model.filter == .mentions ? "at" : "bell",
                description: Text(
                    model.filter == .mentions
                        ? "Posts that mention you will appear here."
                        : "New activity will appear here."
                )
            )
        } else {
            List(model.visibleGroups) { group in
                notificationRow(for: group)
                .listRowBackground(group.isRead ? Color.clear : Color.accentColor.opacity(0.06))
                .task {
                    async let pagination: Void = model.loadMore(
                        after: group,
                        using: services.appViewRequest
                    )
                    async let preview: Void = model.loadPostPreview(
                        for: group.latest,
                        using: services.appViewRequest
                    )
                    _ = await (pagination, preview)
                }
            }
            .listStyle(.plain)
            .refreshable {
                await refreshNotifications()
            }
            .overlay(alignment: .bottom) {
                if model.isLoadingMore {
                    ProgressView()
                        .padding()
                }
            }
        }
    }

    private func notificationRow(for group: NotificationsModel.NotificationGroup) -> some View {
        let postURI = model.postURI(for: group.latest)
        let contextURI = model.contextPostURI(for: group.latest)
        return NotificationGroupRow(
            group: group,
            postURI: postURI,
            postPreview: postURI.flatMap { model.postPreviews[$0] },
            contextURI: contextURI,
            contextPreview: contextURI.flatMap { model.postPreviews[$0] },
            isPostUnavailable: postURI.map { model.failedPostURIs.contains($0) } ?? false,
            isContextUnavailable: contextURI.map { model.failedPostURIs.contains($0) } ?? false,
            onOpen: { openAndMarkRead(group.latest) },
            onOpenContext: { if let contextURI { openThread(contextURI) } },
            onRetry: { Task { await model.loadPostPreview(for: group.latest, using: services.appViewRequest) } },
            onShowActors: { actorGroup = group },
            onOpenAuthor: { author in
                guard let actor = try? ActorIdentifier(author.did) else { return }
                navigator?(.profile(actor))
            }
        )
    }

    private func refreshNotifications() async {
        if await model.refreshAndMarkPreviouslyLoadedRead(
            using: services.appViewRequest,
            procedure: services.appViewProcedure
        ) {
            await services.notificationBadge.refresh()
        }
    }

    private var readErrorBinding: Binding<Bool> {
        Binding(
            get: { model.readErrorMessage != nil },
            set: { if !$0 { model.dismissReadError() } }
        )
    }

    private func openAndMarkRead(_ notification: NotificationsModel.NotificationItem) {
        Task {
            if await model.markRead(through: notification.indexedAt, using: services.appViewProcedure) {
                await services.notificationBadge.refresh()
            }
        }
        open(notification)
    }

    private func open(_ notification: NotificationsModel.NotificationItem) {
        if notification.reason == "follow" || notification.reason == "contact-match" {
            guard let actor = try? ActorIdentifier(notification.author.did) else { return }
            navigator?(.profile(actor))
            return
        }

        guard let target = model.postURI(for: notification) else { return }
        openThread(target)
    }

    private func openThread(_ target: String) {
        guard let uri = try? ATURI(target) else { return }
        navigator?(.thread(uri))
    }
}

#endif
