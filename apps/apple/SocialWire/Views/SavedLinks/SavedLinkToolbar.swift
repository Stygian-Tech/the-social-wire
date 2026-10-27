import SwiftUI

struct SavedLinkToolbar: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.openURL) private var openURL

    let save: MergedLatrSave
    let resolvedURL: URL?
    let isArchivedView: Bool
    @State private var confirmingDelete = false
    @State private var deleteFeedback = 0

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let url = resolvedURL {
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
        .sensoryFeedback(.success, trigger: deleteFeedback)
    }
}
