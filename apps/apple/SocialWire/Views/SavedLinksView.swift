import SwiftUI

struct SavedLinksView: View {
    @Environment(SocialWireAppModel.self) private var appModel

    var body: some View {
        @Bindable var model = appModel

        List(selection: $model.selectedSavedLink) {
            if appModel.savedLinks.isEmpty {
                ContentUnavailableView("No Saved Links", systemImage: "archivebox")
            } else {
                ForEach(appModel.savedLinks) { save in
                    SavedLinkRow(save: save)
                        .tag(save)
                        .swipeActions {
                            Button("Archive") {
                                Task { await appModel.archive(save) }
                            }
                            .tint(.orange)
                            Button("Delete", role: .destructive) {
                                Task { await appModel.delete(save) }
                            }
                        }
                }
            }
        }
        .navigationTitle("Saved Links")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { appModel.savedLinks = (try? await appModel.pds.listMergedLatrSaves()) ?? appModel.savedLinks }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
    }
}

struct SavedLinkRow: View {
    let save: MergedLatrSave

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(save.title)
                .font(.headline)
                .lineLimit(2)
            if let host = save.url?.host {
                Text(host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(save.savedAt)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

struct SavedLinkDetailView: View {
    let save: MergedLatrSave

    var body: some View {
        if let url = save.url {
            WebPreview(url: url)
                .navigationTitle(save.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ShareLink(item: url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
        } else {
            ContentUnavailableView("No Preview", systemImage: "archivebox")
        }
    }
}
