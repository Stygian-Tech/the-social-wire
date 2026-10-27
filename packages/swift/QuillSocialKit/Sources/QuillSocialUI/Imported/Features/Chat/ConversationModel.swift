#if os(iOS)
import Foundation
import Observation

@MainActor
@Observable
final class ConversationModel {
    let conversationID: String
    private(set) var conversation: ChatModels.Conversation?
    private(set) var messages: [ChatModels.Message] = []
    private(set) var currentDID = ""
    private(set) var isLoading = false
    private(set) var isSending = false
    private(set) var didFail = false
    private var cursor: String?

    init(conversationID: String) {
        self.conversationID = conversationID
    }

    func load(services: AppServices) async {
        guard messages.isEmpty, !isLoading else { return }
        isLoading = true
        didFail = false
        defer { isLoading = false }
        do {
            async let did = services.currentAccountDID()
            async let convoData = services.chatRequest(
                "chat.bsky.convo.getConvo",
                ["convoId": conversationID]
            )
            async let messageData = services.chatRequest(
                "chat.bsky.convo.getMessages",
                ["convoId": conversationID, "limit": "50"]
            )
            let (resolvedDID, resolvedConvo, resolvedMessages) = try await (did, convoData, messageData)
            currentDID = resolvedDID
            conversation = try ChatModels.decoder.decode(ConversationResponse.self, from: resolvedConvo).convo
            let response = try ChatModels.decoder.decode(MessagesResponse.self, from: resolvedMessages)
            messages = response.messages.sorted { $0.sentAt < $1.sentAt }
            cursor = response.cursor
            await markRead(services: services)
        } catch {
            didFail = true
        }
    }

    func loadEarlier(services: AppServices) async {
        guard let cursor else { return }
        do {
            let data = try await services.chatRequest(
                "chat.bsky.convo.getMessages",
                ["convoId": conversationID, "limit": "50", "cursor": cursor]
            )
            let response = try ChatModels.decoder.decode(MessagesResponse.self, from: data)
            messages = (response.messages + messages).sorted { $0.sentAt < $1.sentAt }
            self.cursor = response.cursor
        } catch { return }
    }

    func send(
        _ text: String,
        replyingTo: ChatModels.Message? = nil,
        services: AppServices
    ) async -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return false }
        isSending = true
        defer { isSending = false }
        do {
            var messagePayload: [String: Any] = ["text": text]
            if let replyingTo {
                messagePayload["replyTo"] = ["messageId": replyingTo.id]
            }
            let body = try JSONSerialization.data(withJSONObject: [
                "convoId": conversationID,
                "message": messagePayload,
            ])
            let data = try await services.chatProcedure("chat.bsky.convo.sendMessage", body)
            let message = try ChatModels.decoder.decode(ChatModels.Message.self, from: data)
            messages.append(message)
            return true
        } catch {
            return false
        }
    }

    func toggleReaction(_ value: String, on message: ChatModels.Message, services: AppServices) async {
        let hasReaction = message.reactions.contains { $0.sender.did == currentDID && $0.value == value }
        let endpoint = hasReaction ? "chat.bsky.convo.removeReaction" : "chat.bsky.convo.addReaction"
        do {
            let body = try JSONSerialization.data(withJSONObject: [
                "convoId": conversationID,
                "messageId": message.id,
                "value": value,
            ])
            let data = try await services.chatProcedure(endpoint, body)
            let response = try ChatModels.decoder.decode(MessageResponse.self, from: data)
            replace(response.message)
        } catch { return }
    }

    func delete(_ message: ChatModels.Message, services: AppServices) async {
        do {
            let body = try JSONSerialization.data(withJSONObject: [
                "convoId": conversationID,
                "messageId": message.id,
            ])
            _ = try await services.chatProcedure("chat.bsky.convo.deleteMessageForSelf", body)
            messages.removeAll { $0.id == message.id }
        } catch { return }
    }

    func toggleMute(services: AppServices) async {
        guard let conversation else { return }
        let endpoint = conversation.muted ? "chat.bsky.convo.unmuteConvo" : "chat.bsky.convo.muteConvo"
        do {
            let body = try JSONSerialization.data(withJSONObject: ["convoId": conversationID])
            let data = try await services.chatProcedure(endpoint, body)
            self.conversation = try ChatModels.decoder.decode(ConversationResponse.self, from: data).convo
        } catch { return }
    }

    func accept(services: AppServices) async {
        do {
            let body = try JSONSerialization.data(withJSONObject: ["convoId": conversationID])
            _ = try await services.chatProcedure("chat.bsky.convo.acceptConvo", body)
            let data = try await services.chatRequest(
                "chat.bsky.convo.getConvo",
                ["convoId": conversationID]
            )
            conversation = try ChatModels.decoder.decode(ConversationResponse.self, from: data).convo
        } catch { return }
    }

    func leave(services: AppServices) async -> Bool {
        do {
            let body = try JSONSerialization.data(withJSONObject: ["convoId": conversationID])
            _ = try await services.chatProcedure("chat.bsky.convo.leaveConvo", body)
            return true
        } catch {
            return false
        }
    }

    private func markRead(services: AppServices) async {
        guard let newest = messages.last else { return }
        let body = try? JSONSerialization.data(withJSONObject: [
            "convoId": conversationID,
            "messageId": newest.id,
        ])
        guard let body else { return }
        _ = try? await services.chatProcedure("chat.bsky.convo.updateRead", body)
    }

    private func replace(_ message: ChatModels.Message) {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        messages[index] = message
    }
}

private extension ConversationModel {
    struct ConversationResponse: Decodable {
        let convo: ChatModels.Conversation
    }

    struct MessagesResponse: Decodable {
        let cursor: String?
        let messages: [ChatModels.Message]
    }

    struct MessageResponse: Decodable {
        let message: ChatModels.Message
    }
}

#endif
