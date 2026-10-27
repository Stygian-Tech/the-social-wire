import SwiftUI

struct SavedLinkDetailView: View {
    @Environment(SocialWireAppModel.self) private var appModel

    let save: MergedLatrSave
    @State private var socialEntry: EntryDetail?

    private var isArchivedView: Bool {
        appModel.readerListSource == .archive || save.state == "archived"
    }

    private var previewURL: URL? {
        if let directURL = SavedLinkEmbedURL.previewURL(for: save) {
            return directURL
        }
        guard save.subjectUri?.hasPrefix("at://") == true else { return nil }
        return socialEntry?.canonicalURL
    }

    var body: some View {
        Group {
            if let url = previewURL {
                VStack(spacing: 0) {
                    SavedLinkToolbar(
                        save: save,
                        resolvedURL: url,
                        isArchivedView: isArchivedView
                    )
                    .padding(.horizontal)
                    .padding(.vertical, 8)

                    WebPreview(url: url)
                        .accessibilityLabel("Article content")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView(
                    "Preview Unavailable",
                    systemImage: "archivebox",
                    description: Text("This saved item does not have a readable web URL yet.")
                )
            }
        }
        .task(id: save.id) {
            await loadSocialEntry()
        }
    }

    private func loadSocialEntry() async {
        socialEntry = await appModel.savedLinkSocialEntry(for: save)
    }
}
