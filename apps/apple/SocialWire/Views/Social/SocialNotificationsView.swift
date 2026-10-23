import SwiftUI

struct SocialNotificationsView: View {
    @Bindable var model: SocialNotificationsModel
    let navigate: (SocialRoute) -> Void
    var body: some View {
        List {
            ForEach(model.notifications) { notification in
                Button { if let subject = notification.reasonSubject ?? notification.post?.uri { navigate(.post(uri: subject)) } else { navigate(.profile(did: notification.author.did)) } } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: icon(notification.reason)).foregroundStyle(notification.isRead ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
                        SocialAvatarView(url: notification.author.avatar, name: notification.author.preferredName, size: 36)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(notification.author.preferredName) \(verb(notification.reason))")
                            if let text = notification.post?.text, !text.isEmpty { Text(text).font(.subheadline).foregroundStyle(.secondary).lineLimit(3) }
                            Text(notification.indexedAt, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.buttonStyle(.plain)
            }
        }
        .refreshable { await model.refresh() }
        .toolbar { Button("Mark All As Read") { Task { await model.markAllRead() } }.disabled(model.unreadCount == 0) }
        .overlay { if model.isLoading && model.notifications.isEmpty { ProgressView() } else if let error = model.error, model.notifications.isEmpty { ContentUnavailableView("Notifications Unavailable", systemImage: "bell.slash", description: Text(error)) } }
        .task { if model.notifications.isEmpty { await model.refresh() } }
    }

    private func icon(_ reason: String) -> String { switch reason { case "like": "heart.fill"; case "repost": "arrow.2.squarepath"; case "follow": "person.badge.plus"; case "mention": "at"; case "quote": "quote.bubble"; default: "bubble.left" } }
    private func verb(_ reason: String) -> String { switch reason { case "like": "liked your post"; case "repost": "reposted your post"; case "follow": "followed you"; case "mention": "mentioned you"; case "quote": "quoted your post"; default: "replied to you" } }
}
