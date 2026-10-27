#if os(iOS)
import Foundation
import Observation

@MainActor
@Observable
final class ChatModel {
    private(set) var conversations: [ChatModels.Conversation] = []
    private(set) var currentDID = ""
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var didFail = false
    private var cursor: String?

    func load(services: AppServices) async {
        guard conversations.isEmpty, !isLoading else { return }
        await fetch(replacing: true, services: services)
    }

    func refresh(services: AppServices) async {
        await fetch(replacing: true, services: services)
    }

    func loadMore(after conversation: ChatModels.Conversation, services: AppServices) async {
        guard conversation.id == conversations.last?.id, cursor != nil, !isLoadingMore else { return }
        await fetch(replacing: false, services: services)
    }

    func conversation(with did: String, services: AppServices) async throws -> String {
        let data = try await services.chatRequest(
            "chat.bsky.convo.getConvoForMembers",
            ["members": did]
        )
        return try ChatModels.decoder.decode(ConversationResponse.self, from: data).convo.id
    }

    private func fetch(replacing: Bool, services: AppServices) async {
        if replacing { isLoading = true } else { isLoadingMore = true }
        didFail = false
        defer { isLoading = false; isLoadingMore = false }
        do {
            async let did = services.currentAccountDID()
            var parameters = ["limit": "50"]
            if !replacing, let cursor { parameters["cursor"] = cursor }
            async let data = services.chatRequest("chat.bsky.convo.listConvos", parameters)
            let (resolvedDID, resolvedData) = try await (did, data)
            let response = try ChatModels.decoder.decode(Response.self, from: resolvedData)
            currentDID = resolvedDID
            conversations = replacing ? response.convos : conversations + response.convos
            cursor = response.cursor
        } catch {
            didFail = true
        }
    }
}

private extension ChatModel {
    struct Response: Decodable {
        let cursor: String?
        let convos: [ChatModels.Conversation]
    }

    struct ConversationResponse: Decodable {
        let convo: ChatModels.Conversation
    }
}

#endif
