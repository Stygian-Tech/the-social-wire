import SwiftUI

struct PublicationsPaneView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Binding var showingNewFolder: Bool
    @Binding var showingAddPublication: Bool
    var navigateToPane: (ReaderPane) -> Void

    var body: some View {
        @Bindable var model = appModel

        Group {
            switch appModel.readerListSource {
            case .readLater:
                SavedLinksListContent(
                    onSelectSave: {
                        navigateToPane(.reader)
                    }
                )
            case .subscribed:
                List(selection: $model.selectedSidebar) {
                    SubscribedPublicationSidebarTree(
                        showingNewFolder: $showingNewFolder,
                        showingAddPublication: $showingAddPublication
                    )
                }
                .onChange(of: model.selectedSidebar) { _, selection in
                    guard case .publication = selection else { return }
                    navigateToPane(.articles)
                }
            case .following:
                List(selection: $model.selectedSidebar) {
                    FollowingPublicationSidebarTree()
                }
                .onChange(of: model.selectedSidebar) { _, selection in
                    guard case .publication = selection else { return }
                    navigateToPane(.articles)
                }
            }
        }
    }
}

/// Read-later rows for the publications pane (no local toolbar).
struct SavedLinksListContent: View {
    @Environment(SocialWireAppModel.self) private var appModel
    var onSelectSave: (() -> Void)?

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
                .onChange(of: model.selectedSavedLink?.id) { _, saveId in
                    guard saveId != nil else { return }
                    onSelectSave?()
                }
            } else {
                ContentUnavailableView(
                    "Read-Later List Unavailable",
                    systemImage: "link.badge.plus",
                    description: savedListUnavailableDescription
                )
            }
        }
    }
}
