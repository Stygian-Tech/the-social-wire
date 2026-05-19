import SwiftUI

struct SavedLinksView: View {
    @Environment(SocialWireAppModel.self) private var appModel

    private var savedListUnavailableDescription: Text {
        let chosen = ReadLaterServiceCatalog.label(for: appModel.effectiveReadLaterServiceId)
        return Text("""
            L@tr Link merges HTTPS read-later URLs from your PDS. You have \(chosen) selected. \
            Use that provider in its own app or site for now, or choose L@tr Link under Read Later in Settings.
            """)
    }

    var body: some View {
        @Bindable var model = appModel

        Group {
            if appModel.readLaterLatrConfigured {
                savedLinksMainList(model: model)
            } else {
                readLaterMisconfiguredPlaceholder
            }
        }
        .navigationTitle("Saved Links")
    }

    @ViewBuilder
    private func savedLinksMainList(@Bindable model: SocialWireAppModel) -> some View {
        SavedLinksListContent()
    }

    @ViewBuilder
    private var readLaterMisconfiguredPlaceholder: some View {
        ContentUnavailableView(
            "Read-Later List Unavailable",
            systemImage: "link.badge.plus",
            description: savedListUnavailableDescription
        )
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
    @Environment(SocialWireAppModel.self) private var appModel

    let save: MergedLatrSave

    var body: some View {
        Group {
            if let url = save.url {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        ShareLink(item: url) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)

                        Link(destination: url) {
                            Label("Open", systemImage: "safari")
                        }
                        .buttonStyle(.bordered)

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)

                    WebPreview(url: url)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView(
                    "Preview Unavailable",
                    systemImage: "archivebox",
                    description: Text("Native ATProto saved item previews are not available yet.")
                )
            }
        }
    }
}
