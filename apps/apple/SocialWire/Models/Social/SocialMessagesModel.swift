import Foundation
import Observation

@MainActor
@Observable
final class SocialMessagesModel {
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var selectionGeneration = UUID()
    private let client: SocialWireSocialClient
    @ObservationIgnored private var readTask: Task<Void, Never>?
    private(set) var conversations: [SocialConversation] = []
    private(set) var messages: [SocialMessage] = []
    private(set) var selectedConversationID: String?
    private(set) var viewerDID: String?
    private(set) var isLoading = false
    private(set) var error: String?

    init(client: SocialWireSocialClient) { self.client = client }

    func reset() {
        generation = UUID()
        selectionGeneration = UUID()
        readTask?.cancel()
        readTask = nil
        conversations = []
        messages = []
        selectedConversationID = nil
        viewerDID = nil
        isLoading = false
        error = nil
    }

    func refreshConversations() async {
        let current = generation
        isLoading = true
        error = nil
        defer { if generation == current { isLoading = false } }
        do {
            let loaded = try await client.conversations().items
            guard generation == current else { return }
            let viewer = try await client.viewerDID()
            guard generation == current else { return }
            conversations = loaded
            viewerDID = viewer
        } catch is CancellationError { } catch {
            if generation == current { self.error = error.localizedDescription }
        }
    }

    func select(_ conversation: SocialConversation) async {
        readTask?.cancel()
        selectionGeneration = UUID()
        let selection = selectionGeneration
        let current = generation
        selectedConversationID = conversation.id
        messages = []
        error = nil
        isLoading = true
        defer { if generation == current, selectionGeneration == selection { isLoading = false } }
        do {
            let loaded = try await client.messages(conversationID: conversation.id).items
            guard generation == current, selectionGeneration == selection else { return }
            messages = loaded.sorted { $0.sentAt < $1.sentAt }
            scheduleRead(conversation: conversation, newestLoadedID: loaded.first?.id)
        } catch is CancellationError { } catch {
            if generation == current, selectionGeneration == selection { self.error = error.localizedDescription }
        }
    }

    func send(_ text: String, replyTo: SocialMessageReference? = nil) async -> Bool {
        let current = generation
        let selection = selectionGeneration
        guard let selectedConversationID, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        do {
            let message = try await client.sendMessage(conversationID: selectedConversationID, text: text, replyTo: replyTo)
            guard generation == current, selectionGeneration == selection else { return false }
            messages.append(message)
            return true
        } catch {
            if generation == current, selectionGeneration == selection { self.error = error.localizedDescription }
            return false
        }
    }

    func toggleReaction(_ value: String, on message: SocialMessage) async {
        let current = generation
        let selection = selectionGeneration
        guard let selectedConversationID, let viewerDID else { return }
        do {
            let updated = try await client.toggleReaction(conversationID: selectedConversationID, message: message, value: value, viewerDID: viewerDID)
            guard generation == current, selectionGeneration == selection else { return }
            if let index = messages.firstIndex(where: { $0.id == message.id }) { messages[index] = updated }
        } catch {
            if generation == current, selectionGeneration == selection { self.error = error.localizedDescription }
        }
    }

    func delete(_ message: SocialMessage) async {
        let current = generation
        let selection = selectionGeneration
        guard let selectedConversationID else { return }
        do {
            try await client.deleteMessage(conversationID: selectedConversationID, messageID: message.id)
            guard generation == current, selectionGeneration == selection else { return }
            messages.removeAll { $0.id == message.id }
        } catch {
            if generation == current, selectionGeneration == selection { self.error = error.localizedDescription }
        }
    }

    func toggleMute() async {
        let current = generation
        guard let id = selectedConversationID, let conversation = conversations.first(where: { $0.id == id }) else { return }
        do {
            let updated = try await client.setConversationMuted(id, muted: !conversation.muted)
            guard generation == current, let index = conversations.firstIndex(where: { $0.id == id }) else { return }
            conversations[index] = updated
        } catch { if generation == current { self.error = error.localizedDescription } }
    }

    func accept() async {
        let current = generation
        guard let id = selectedConversationID else { return }
        do {
            try await client.acceptConversation(id)
            guard generation == current else { return }
            await refreshConversations()
        } catch { if generation == current { self.error = error.localizedDescription } }
    }

    func leave() async {
        let current = generation
        let selection = selectionGeneration
        guard let id = selectedConversationID else { return }
        do {
            try await client.leaveConversation(id)
            guard generation == current else { return }
            if selectionGeneration == selection {
                readTask?.cancel()
                selectionGeneration = UUID()
                selectedConversationID = nil
                messages = []
            }
            await refreshConversations()
        } catch { if generation == current { self.error = error.localizedDescription } }
    }

    private func scheduleRead(conversation: SocialConversation, newestLoadedID: String?) {
        let current = generation
        let selection = selectionGeneration
        guard conversation.status != "request", conversation.unreadCount > 0, let newestLoadedID else { return }
        readTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
                guard let self, self.generation == current, self.selectionGeneration == selection else { return }
                try await self.client.markConversationRead(conversation.id, messageID: newestLoadedID)
                guard self.generation == current else { return }
                if let index = self.conversations.firstIndex(where: { $0.id == conversation.id }) {
                    self.conversations[index].unreadCount = 0
                }
            } catch is CancellationError { } catch {
                guard let self, self.generation == current else { return }
                self.error = error.localizedDescription
            }
        }
    }
}
