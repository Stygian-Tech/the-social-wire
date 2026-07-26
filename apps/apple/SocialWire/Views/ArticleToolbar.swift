import SwiftUI

struct ArticleToolbar: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.openURL) private var openURL
    let entry: EntryDetail
    @Binding var showingQuote: Bool
    @Binding var showingReply: Bool
    @State private var reactionFeedback = 0

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    reactionFeedback += 1
                    Task {
                        await appModel.saveEntry(
                            entryId: entry.entryId,
                            url: entry.canonicalURL,
                            title: entry.title,
                            linkedWebURL: entry.embedUrl ?? entry.originalUrl
                        )
                    }
                } label: {
                    Label("Save", systemImage: "bookmark")
                }
                .buttonStyle(.bordered)

                Button {
                    showingQuote = true
                } label: {
                    Label("Quote", systemImage: "quote.bubble")
                }
                .buttonStyle(.bordered)

                if entry.bskyPostUri != nil {
                    Button {
                        showingReply = true
                    } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                    }
                    .buttonStyle(.bordered)
                }

                if let url = entry.canonicalURL {
                    ShareLink(item: url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        openURL(url)
                    } label: {
                        Label("Open", systemImage: "safari")
                    }
                    .buttonStyle(.bordered)
                }

                Button {
                    reactionFeedback += 1
                    Task { await appModel.likeEntry(entry) }
                } label: {
                    Label("Like", systemImage: "heart")
                }
                .buttonStyle(.bordered)
                .disabled(entry.bskyPostUri == nil)

                Button {
                    reactionFeedback += 1
                    Task { await appModel.repostEntry(entry) }
                } label: {
                    Label("Repost", systemImage: "repeat")
                }
                .buttonStyle(.bordered)
                .disabled(entry.bskyPostUri == nil)
            }
        }
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .sensoryFeedback(.success, trigger: reactionFeedback)
    }
}
