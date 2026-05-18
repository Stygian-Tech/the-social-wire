import SwiftUI

struct SavedLinksView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var compact: Bool {
        horizontalSizeClass == .compact
    }

    private var hidesListChrome: Bool {
        compact && appModel.selectedSavedLink != nil
    }

    private var savedListUnavailableDescription: Text {
        let chosen = ReadLaterServiceCatalog.label(for: appModel.effectiveReadLaterServiceId)
        return Text("""
            L@tr Link merges HTTPS read-later URLs from your PDS. You have \(chosen) selected. \
            Use that provider in its own app or site for now, or choose L@tr Link under Read Later in Settings.
            """)
    }

    var body: some View {
        @Bindable var model = appModel

        ZStack {
            readLaterGateRoot(model: model)

            if compact, appModel.readLaterLatrConfigured, let save = model.selectedSavedLink {
                SavedLinkDetailView(save: save, showsCompactChrome: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemBackground))
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private func readLaterGateRoot(@Bindable model: SocialWireAppModel) -> some View {
        Group {
            if appModel.readLaterLatrConfigured {
                savedLinksMainList(model: model)
            } else {
                readLaterMisconfiguredPlaceholder
            }
        }
        .navigationTitle("Saved Links")
        .toolbar(hidesListChrome ? .hidden : .automatic, for: .navigationBar)
        .toolbar {
            if appModel.readLaterLatrConfigured {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            model.savedLinks = (try? await model.pds.listMergedLatrSaves()) ?? model.savedLinks
                        }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .frame(minHeight: 44)
                    .disabled(hidesListChrome)
                }
            }
        }
    }

    @ViewBuilder
    private func savedLinksMainList(@Bindable model: SocialWireAppModel) -> some View {
        List(selection: $model.selectedSavedLink) {
            if appModel.savedLinks.isEmpty {
                ContentUnavailableView(
                    "Nothing Queued Yet",
                    systemImage: "archivebox",
                    description: Text("Save an HTTPS article from the toolbar to queue it here as a LATR Link item.")
                )
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

    /// When `true`, the list column is overlaid full-width — show a predictable **Back to Saved Links** chrome.
    var showsCompactChrome: Bool

    init(save: MergedLatrSave, showsCompactChrome: Bool = false) {
        self.save = save
        self.showsCompactChrome = showsCompactChrome
    }

    var body: some View {
        Group {
            if let url = save.url {
                WebPreview(url: url)
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle(save.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        if showsCompactChrome {
                            ToolbarItem(placement: .topBarLeading) {
                                Button {
                                    appModel.dismissSavedLinkDetail()
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "chevron.backward")
                                        Text("Saved Links")
                                    }
                                    .frame(minHeight: 44)
                                }
                                .accessibilityLabel("Back to Saved Links")
                            }
                        }

                        ToolbarItemGroup(placement: .topBarTrailing) {
                            ShareLink(item: url) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            .frame(minHeight: 44)

                            Link(destination: url) {
                                Label("Open", systemImage: "safari")
                            }
                            .frame(minHeight: 44)
                        }
                    }
            } else {
                ContentUnavailableView(
                    "Preview Unavailable",
                    systemImage: "archivebox",
                    description: Text("Native ATProto saved item previews are not available yet.")
                )
                .navigationTitle(save.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if showsCompactChrome {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                appModel.dismissSavedLinkDetail()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "chevron.backward")
                                    Text("Saved Links")
                                }
                                .frame(minHeight: 44)
                            }
                            .accessibilityLabel("Back to Saved Links")
                        }
                    }
                }
            }
        }
    }
}
