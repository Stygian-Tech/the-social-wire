#if os(iOS)
import SwiftUI

struct ChatView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.routeNavigator) private var navigator
    @State private var model = ChatModel()
    @State private var showsNewChat = false

    var body: some View {
        Group {
            if model.conversations.isEmpty, model.isLoading {
                ProgressView("Loading Chats")
            } else if model.conversations.isEmpty, model.didFail {
                ContentUnavailableView {
                    Label("Chats Unavailable", systemImage: "wifi.exclamationmark")
                } description: {
                    Text("The Social Wire couldn’t load your conversations.")
                } actions: {
                    Button("Try Again") { Task { await model.refresh(services: services) } }
                        .buttonStyle(.borderedProminent)
                }
            } else if model.conversations.isEmpty {
                ContentUnavailableView(
                    "No Conversations",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Start a conversation to see it here.")
                )
            } else {
                List(model.conversations) { conversation in
                    Button {
                        navigator?(.conversation(id: conversation.id))
                    } label: {
                        conversationRow(conversation)
                    }
                    .buttonStyle(.plain)
                    .task { await model.loadMore(after: conversation, services: services) }
                }
                .listStyle(.plain)
                .refreshable { await model.refresh(services: services) }
            }
        }
        .roundedNavigationTitle("Chat", inlineTitleFont: .body.weight(.semibold))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Conversation", systemImage: "square.and.pencil") {
                    showsNewChat = true
                }
            }
        }
        .sheet(isPresented: $showsNewChat) {
            NewChatView { did in
                let id = try await model.conversation(with: did, services: services)
                showsNewChat = false
                navigator?(.conversation(id: id))
            }
        }
        .task { await model.load(services: services) }
    }

    private func conversationRow(_ conversation: ChatModels.Conversation) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: conversation.avatar(currentDID: model.currentDID)) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: conversation.kind?.memberCount == nil ? "person.crop.circle.fill" : "person.2.circle.fill")
                    .resizable().foregroundStyle(.secondary)
            }
            .frame(width: 52, height: 52)
            .clipShape(.circle)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(conversation.title(currentDID: model.currentDID))
                        .font(conversation.unreadCount > 0 ? .headline.bold() : .headline)
                        .lineLimit(1)
                    Spacer()
                    if let date = conversation.lastMessage?.sentAt {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(inboxTimestamp(for: date, relativeTo: context.date))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text(conversation.lastMessage?.summary ?? "No messages yet")
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    if conversation.status == "request" {
                        Text("Request")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                    if conversation.muted { Image(systemName: "bell.slash.fill").foregroundStyle(.secondary) }
                    if conversation.unreadCount > 0 {
                        Text(conversation.unreadCount, format: .number)
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(.tint, in: .circle)
                    }
                }
            }
        }
        .contentShape(.rect)
        .padding(.vertical, 3)
    }

    private func inboxTimestamp(for date: Date, relativeTo now: Date) -> String {
        let start = min(date, now)
        let end = max(date, now)
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: start,
            to: end
        )

        if let years = components.year, years > 0 { return "\(years)y" }
        if let months = components.month, months > 0 { return "\(months)mo" }
        if let days = components.day, days > 0 { return "\(days)d" }
        if let hours = components.hour, hours > 0 { return "\(hours)h" }
        if let minutes = components.minute, minutes > 0 { return "\(minutes)m" }
        return "\(max(components.second ?? 0, 0))s"
    }
}

#endif
