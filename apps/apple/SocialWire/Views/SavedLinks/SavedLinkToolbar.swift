import SwiftUI

struct SavedLinkToolbar: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.openURL) private var openURL

    let save: MergedLatrSave
    let entry: EntryDetail?
    let isArchivedView: Bool
    @Binding var showingQuote: Bool
    @Binding var showingReply: Bool
    @State private var confirmingDelete = false
    @State private var reactionFeedback = 0
    @State private var deleteFeedback = 0

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let url = SavedLinkEmbedURL.previewURL(for: save) {
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
                    showingQuote = true
                } label: {
                    Label("Quote", systemImage: "quote.bubble")
                }
                .buttonStyle(.bordered)

                if entry?.bskyPostUri != nil {
                    Button {
                        reactionFeedback += 1
                        Task { await appModel.likeEntry(entry!) }
                    } label: {
                        Label("Like", systemImage: "heart")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        reactionFeedback += 1
                        Task { await appModel.repostEntry(entry!) }
                    } label: {
                        Label("Repost", systemImage: "repeat")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        showingReply = true
                    } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                    }
                    .buttonStyle(.bordered)
                }

                if isArchivedView {
                    Button {
                        Task { await appModel.unarchive(save) }
                    } label: {
                        Label("Unarchive", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        Task { await appModel.archive(save) }
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                    .buttonStyle(.bordered)
                }

                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Delete saved link")
            }
        }
        .confirmationDialog("Delete this saved link?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    await appModel.delete(save)
                    deleteFeedback += 1
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sensoryFeedback(.success, trigger: reactionFeedback)
        .sensoryFeedback(.success, trigger: deleteFeedback)
    }
}
