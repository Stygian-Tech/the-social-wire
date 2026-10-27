#if os(iOS)
import ATProtoCore
import SwiftUI

struct ConversationView: View {
    let conversationID: String

    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @Environment(\.routeNavigator) private var navigator
    @State private var model: ConversationModel
    @State private var draft = ""
    @State private var replyingTo: ChatModels.Message?
    @State private var reactionTarget: ChatModels.Message?
    @State private var showsLeaveConfirmation = false

    init(conversationID: String) {
        self.conversationID = conversationID
        _model = State(initialValue: ConversationModel(conversationID: conversationID))
    }

    var body: some View {
        Group {
            if model.messages.isEmpty, model.isLoading {
                ProgressView("Loading Conversation")
            } else if model.messages.isEmpty, model.didFail {
                ContentUnavailableView("Conversation Unavailable", systemImage: "wifi.exclamationmark")
            } else {
                VStack(spacing: 0) {
                    if model.conversation?.status == "request" {
                        requestBanner
                    }
                    messageList
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { conversationToolbar }
        .confirmationDialog(
            "Leave Conversation?",
            isPresented: $showsLeaveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Leave Conversation", role: .destructive) {
                Task {
                    if await model.leave(services: services) { dismiss() }
                }
            }
        } message: {
            Text("This removes the conversation from your inbox.")
        }
        .sheet(item: $reactionTarget) { message in
            ReactionPickerView { reaction in
                Task {
                    await model.toggleReaction(reaction, on: message, services: services)
                }
            }
            .presentationDetents([.height(190)])
        }
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "quill", url.host == "profile" else { return .systemAction }
            guard let did = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "did" })?.value,
                  let actor = try? ActorIdentifier(did), let navigator else { return .discarded }
            navigator(.profile(actor))
            return .handled
        })
        .task { await model.load(services: services) }
    }

    private var conversationTitle: String {
        model.conversation?.title(currentDID: model.currentDID) ?? "Conversation"
    }

    private var otherMember: ChatModels.Profile? {
        model.conversation?.members.first { $0.did != model.currentDID }
    }

    private var conversationHeader: some View {
        VStack(spacing: 4) {
            AsyncImage(url: otherMember?.avatar) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(
                    systemName: model.conversation?.kind?.memberCount == nil
                        ? "person.crop.circle.fill"
                        : "person.2.circle.fill"
                )
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
            }
            .frame(width: 44, height: 44)
            .background(.fill.tertiary, in: .circle)
            .clipShape(.circle)

            Text(conversationTitle)
                .font(.headline)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    if !model.messages.isEmpty {
                        Button("Load Earlier Messages") {
                            Task { await model.loadEarlier(services: services) }
                        }
                        .font(.caption)
                        .padding(.vertical, 6)
                    }

                    ForEach(model.messages) { message in
                        messageRow(message)
                            .id(message.id)
                    }
                }
                .padding()
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: model.messages.count) { _, _ in
                if let id = model.messages.last?.id {
                    withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
    }

    private var requestBanner: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Message Request")
                    .font(.headline)
                Text("Accept this request to continue the conversation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Accept") {
                Task { await model.accept(services: services) }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.bar)
    }

    private func messageRow(_ message: ChatModels.Message) -> some View {
        let isOwn = message.sender?.did == model.currentDID
        return HStack {
            if isOwn { Spacer(minLength: 48) }
            VStack(alignment: isOwn ? .trailing : .leading, spacing: 4) {
                messageBubble(message, isOwn: isOwn)
                    .swipeToReply {
                        replyingTo = message
                    }

                if !message.reactions.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(message.reactions) { reaction in Text(reaction.value) }
                    }
                    .font(.caption)
                }
            }
            .contextMenu {
                Button("Reply", systemImage: "arrowshape.turn.up.left") {
                    replyingTo = message
                }
                Button("Add Reaction", systemImage: "face.smiling") {
                    reactionTarget = message
                }
                Divider()
                Button("Delete for Me", systemImage: "trash", role: .destructive) {
                    Task { await model.delete(message, services: services) }
                }
            }
            if !isOwn { Spacer(minLength: 48) }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func messageBubble(_ message: ChatModels.Message, isOwn: Bool) -> some View {
        if let text = message.text {
            VStack(alignment: .leading, spacing: 6) {
                if let reply = message.replyTo {
                    replyPreview(reply)
                }
                if let gifURL = message.gifURL {
                    AnimatedImageView(url: gifURL)
                        .frame(width: 240, height: 180)
                        .clipShape(.rect(cornerRadius: 12))
                        .accessibilityLabel("Animated GIF")
                }
                if message.gifURL?.absoluteString != text.trimmingCharacters(in: .whitespacesAndNewlines) {
                    Text(ChatLinkDetector.attributedText(text, facets: message.facets))
                        .tint(isOwn ? .white : .accentColor)
                }
                ForEach(message.linkURLs.filter { $0 != message.gifURL }, id: \.self) { url in
                    ChatLinkPreviewView(url: url)
                }
            }
            .foregroundStyle(isOwn ? .white : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                isOwn ? Color.accentColor : Color.secondary.opacity(0.16),
                in: .rect(cornerRadius: 16)
            )
        } else {
            Text("Message deleted")
                .font(.caption.italic())
                .foregroundStyle(.secondary)
        }
    }

    private func replyPreview(_ reply: ChatModels.ReplyPreview) -> some View {
        HStack(spacing: 6) {
            Capsule()
                .fill(.white.opacity(0.65))
                .frame(width: 3)
            Text(reply.text?.isEmpty == false ? reply.text ?? "" : "Message unavailable")
                .font(.caption)
                .lineLimit(2)
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel("Replying to: \(reply.text ?? "message unavailable")")
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let replyingTo {
                HStack(spacing: 8) {
                    Image(systemName: "arrowshape.turn.up.left")
                    Text(replyingTo.text?.isEmpty == false ? replyingTo.text ?? "" : "Message unavailable")
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Button("Cancel Reply", systemImage: "xmark.circle.fill") {
                        self.replyingTo = nil
                    }
                    .labelStyle(.iconOnly)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .padding(.leading, 4)

                Button("Send", systemImage: "arrow.up.circle.fill") {
                    let value = draft
                    Task {
                        if await model.send(value, replyingTo: replyingTo, services: services) {
                            draft = ""
                            replyingTo = nil
                        }
                    }
                }
                .labelStyle(.iconOnly)
                .font(.title2)
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .disabled(
                    draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || model.isSending
                        || model.conversation?.status == "request"
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .quillComposerSurface()
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    @ToolbarContentBuilder
    private var conversationToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            conversationHeader
        }

        ToolbarItemGroup(placement: .secondaryAction) {
            Button(
                model.conversation?.muted == true ? "Unmute" : "Mute",
                systemImage: model.conversation?.muted == true ? "bell" : "bell.slash"
            ) {
                Task { await model.toggleMute(services: services) }
            }
            Button("Leave Conversation", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                showsLeaveConfirmation = true
            }
        }
    }
}

#endif
