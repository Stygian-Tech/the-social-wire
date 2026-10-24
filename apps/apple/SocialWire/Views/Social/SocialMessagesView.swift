import SwiftUI

struct SocialMessagesView: View {
    @Bindable var model: SocialMessagesModel
    @State private var text = ""
    @State private var deletingMessage: SocialMessage?
    @State private var confirmLeave = false

    var body: some View {
        NavigationSplitView {
            List(model.conversations, selection: Binding(get: { model.selectedConversationID }, set: { id in if let conversation = model.conversations.first(where: { $0.id == id }) { Task { await model.select(conversation) } } })) { conversation in
                SocialConversationRow(conversation: conversation).tag(conversation.id)
            }
            .navigationTitle("Messages")
            .refreshable { await model.refreshConversations() }
        } detail: {
            if model.selectedConversationID == nil { ContentUnavailableView("Select a Conversation", systemImage: "message") }
            else {
                SocialConversationView(messages: model.messages, viewerDID: model.viewerDID, text: $text, react: { value, message in Task { await model.toggleReaction(value, on: message) } }, delete: { deletingMessage = $0 }) { value in if await model.send(value) { text = "" } }
                    .toolbar {
                        ToolbarItemGroup(placement: .primaryAction) {
                            if model.conversations.first(where: { $0.id == model.selectedConversationID })?.status == "request" { Button("Accept", systemImage: "checkmark") { Task { await model.accept() } } }
                            Menu("Conversation Actions", systemImage: "ellipsis.circle") {
                                Button(model.conversations.first(where: { $0.id == model.selectedConversationID })?.muted == true ? "Unmute Conversation" : "Mute Conversation", systemImage: "speaker.slash") { Task { await model.toggleMute() } }
                                Button("Leave Conversation", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { confirmLeave = true }
                            }
                        }
                    }
            }
        }
        .task { if model.conversations.isEmpty { await model.refreshConversations() } }
        .confirmationDialog("Delete This Message?", isPresented: Binding(get: { deletingMessage != nil }, set: { if !$0 { deletingMessage = nil } }), titleVisibility: .visible) {
            Button("Delete Message", role: .destructive) { if let message = deletingMessage { Task { await model.delete(message) } }; deletingMessage = nil }
        }
        .confirmationDialog("Leave This Conversation?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave Conversation", role: .destructive) { Task { await model.leave() } }
        }
    }
}

private struct SocialConversationRow: View {
    let conversation: SocialConversation
    var body: some View {
        HStack { SocialAvatarView(url: conversation.members.first?.avatar, name: conversation.members.first?.preferredName ?? "Conversation", size: 38); VStack(alignment: .leading) { Text(conversation.members.map(\.preferredName).formatted(.list(type: .and))).lineLimit(1); if let last = conversation.lastMessage { Text(last.text).font(.caption).foregroundStyle(.secondary).lineLimit(1) } }; Spacer(); if conversation.unreadCount > 0 { Text(conversation.unreadCount, format: .number).font(.caption2).padding(6).background(.tint, in: .circle).foregroundStyle(.white) } }
    }
}

private struct SocialConversationView: View {
    let messages: [SocialMessage]
    let viewerDID: String?
    @Binding var text: String
    let react: (String, SocialMessage) -> Void
    let delete: (SocialMessage) -> Void
    let send: (String) async -> Void
    var body: some View {
        VStack(spacing: 0) {
            List(messages) { message in
                VStack(alignment: .leading, spacing: 4) {
                    Text(message.text)
                    if !message.reactions.isEmpty { Text(message.reactions.map(\.value).joined(separator: " ")).font(.caption) }
                    Text(message.sentAt, format: .dateTime.hour().minute()).font(.caption2).foregroundStyle(.secondary)
                }
                .contextMenu {
                    ForEach(["❤️", "👍", "😂", "😮", "😢", "🙏"], id: \.self) { value in Button(value) { react(value, message) } }
                    if message.senderDID == viewerDID { Button("Delete Message", systemImage: "trash", role: .destructive) { delete(message) } }
                }
            }
            HStack { TextField("Message", text: $text, axis: .vertical).textFieldStyle(.roundedBorder); Button("Send", systemImage: "arrow.up.circle.fill") { let value = text; Task { await send(value) } }.labelStyle(.iconOnly).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }.padding()
        }
    }
}
