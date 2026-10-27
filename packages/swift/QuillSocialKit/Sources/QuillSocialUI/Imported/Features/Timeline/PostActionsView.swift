#if os(iOS)
import Feeds
import SwiftUI

struct PostActionsView: View {
    @State private var model: PostActionsModel
    @Environment(AppServices.self) private var services

    init(post: TimelinePost) {
        model = PostActionsModel(post: post)
    }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                model.isReplyPresented = true
            } label: {
                actionLabel("Reply", systemImage: "bubble", count: model.post.replyCount)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                Button {
                    Task { await model.toggleRepost(using: services.postActionSource) }
                } label: {
                    Label(
                        model.repostURI == nil ? "Repost" : "Undo Repost",
                        systemImage: "arrow.2.squarepath"
                    )
                }
                .disabled(model.isUpdatingRepost)

                Button {
                    model.isQuotePresented = true
                } label: {
                    Label("Quote Post", systemImage: "quote.bubble")
                }
            } label: {
                actionLabel(
                    "Reposts and Quotes",
                    systemImage: "arrow.2.squarepath",
                    count: model.repostAndQuoteCount,
                    activeColor: model.hasRepostedOrQuoted ? .green : nil
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                Task { await model.toggleLike(using: services.postActionSource) }
            } label: {
                actionLabel(
                    "Like",
                    systemImage: model.likeURI == nil ? "heart" : "heart.fill",
                    count: model.likeCount,
                    activeColor: model.likeURI == nil ? nil : .red
                )
            }
            .disabled(model.isUpdatingLike)
            .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                Button {
                    Task { @MainActor in
                        await Task.yield()
                        model.isTranslationPresented = true
                    }
                } label: {
                    Label("Translate", systemImage: "translate")
                }

                if let url = PostShareURL.url(for: model.post.uri) {
                    ShareLink(item: url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
            }
            .frame(width: 28, alignment: .trailing)
        }
        .buttonStyle(.borderless)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .sensoryFeedback(.success, trigger: model.feedbackGeneration)
        .sensoryFeedback(.error, trigger: model.errorGeneration)
        .sheet(isPresented: $model.isReplyPresented) {
            ReplyComposerView(model: model)
        }
        .sheet(isPresented: $model.isQuotePresented) {
            QuotePostComposerView(model: model)
        }
        .sheet(isPresented: $model.isTranslationPresented) {
            PostTranslationView(text: model.post.text)
        }
    }

    private func actionLabel(
        _ title: LocalizedStringResource,
        systemImage: String,
        count: Int,
        activeColor: Color? = nil
    ) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .frame(width: 18)

            Text("8.8M")
                .hidden()
                .overlay(alignment: .leading) {
                    Text(count, format: .number.notation(.compactName))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .monospacedDigit()
        }
        .foregroundStyle(activeColor ?? .secondary)
        .contentTransition(.symbolEffect(.replace))
        .animation(.easeInOut(duration: 0.2), value: systemImage)
        .animation(.easeInOut(duration: 0.2), value: activeColor)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(count, format: .number))
    }
}

#endif
