import Foundation
import Observation

@MainActor
@Observable
final class SocialMessagesModel {
    private let client: SocialWireSocialClient
    @ObservationIgnored private var readTask: Task<Void, Never>?
    private(set) var conversations: [SocialConversation] = []
    private(set) var messages: [SocialMessage] = []
    private(set) var selectedConversationID: String?
    private(set) var viewerDID: String?
    private(set) var isLoading = false
    private(set) var error: String?

    init(client: SocialWireSocialClient) { self.client = client }

    func refreshConversations() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            conversations = try await client.conversations().items
            viewerDID = try await client.viewerDID()
        }
        catch is CancellationError { } catch { self.error = error.localizedDescription }
    }

    func select(_ conversation: SocialConversation) async {
        readTask?.cancel()
        selectedConversationID = conversation.id
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await client.messages(conversationID: conversation.id).items
            guard selectedConversationID == conversation.id else { return }
            messages = loaded.sorted { $0.sentAt < $1.sentAt }
            scheduleRead(conversation: conversation, newestLoadedID: loaded.first?.id)
        } catch is CancellationError { } catch { self.error = error.localizedDescription }
    }

    func send(_ text: String, replyTo: SocialMessageReference? = nil) async -> Bool {
        guard let selectedConversationID, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        do {
            let message = try await client.sendMessage(conversationID: selectedConversationID, text: text, replyTo: replyTo)
            messages.append(message)
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func toggleReaction(_ value: String, on message: SocialMessage) async {
        guard let selectedConversationID, let viewerDID else { return }
        do {
            let updated = try await client.toggleReaction(conversationID: selectedConversationID, message: message, value: value, viewerDID: viewerDID)
            if let index = messages.firstIndex(where: { $0.id == message.id }) { messages[index] = updated }
        } catch { self.error = error.localizedDescription }
    }

    func delete(_ message: SocialMessage) async {
        guard let selectedConversationID else { return }
        do { try await client.deleteMessage(conversationID: selectedConversationID, messageID: message.id); messages.removeAll { $0.id == message.id } }
        catch { self.error = error.localizedDescription }
    }

    func toggleMute() async {
        guard let id = selectedConversationID, let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        do { conversations[index] = try await client.setConversationMuted(id, muted: !conversations[index].muted) }
        catch { self.error = error.localizedDescription }
    }

    func accept() async {
        guard let id = selectedConversationID else { return }
        do { try await client.acceptConversation(id); await refreshConversations() }
        catch { self.error = error.localizedDescription }
    }

    func leave() async {
        guard let id = selectedConversationID else { return }
        do { try await client.leaveConversation(id); selectedConversationID = nil; messages = []; await refreshConversations() }
        catch { self.error = error.localizedDescription }
    }

    private func scheduleRead(conversation: SocialConversation, newestLoadedID: String?) {
        guard conversation.status != "request", conversation.unreadCount > 0, let newestLoadedID else { return }
        readTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
                guard let self, self.selectedConversationID == conversation.id else { return }
                try await self.client.markConversationRead(conversation.id, messageID: newestLoadedID)
                if let index = self.conversations.firstIndex(where: { $0.id == conversation.id }) {
                    self.conversations[index].unreadCount = 0
                }
            } catch is CancellationError { } catch { self?.error = error.localizedDescription }
        }
    }
}
