import SwiftUI

struct SavedNewsView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.openURL) private var openURL
    let sceneModel: NewsSceneModel
    @State private var showingTagManagement = false

    var body: some View {
        savedList
        .navigationTitle(appModel.savedTabTitle)
        .toolbar {
            if !appModel.isSembleReadLaterEnabled {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingTagManagement = true
                    } label: {
                        Label("Manage Tags", systemImage: "tag")
                    }
                }
            }
        }
        .sheet(isPresented: $showingTagManagement) {
            SavedTagManagementView()
        }
        .task(id: appModel.isSembleReadLaterEnabled) {
            if appModel.isSembleReadLaterEnabled {
                await appModel.refreshSembleCollection()
            } else {
                await appModel.refreshSavedLinks()
            }
        }
        .accessibilityIdentifier("news-tab-content-saved")
    }

    private var savedList: some View {
        Group {
            if appModel.isSembleReadLaterEnabled {
                VStack(spacing: 0) {
                    if appModel.pendingSembleSaveRetry != nil {
                        HStack {
                            Label("Save Pending", systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                                .font(.footnote)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityLabel("A card is waiting to be added to this collection.")
                            Spacer()
                            Button("Resume") { Task { await appModel.resumeSembleSave() } }
                                .buttonStyle(.borderedProminent)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .padding()
                        Divider()
                    }
                    SembleCollectionListContent(onItemTap: openSembleItem)
                }
            } else {
                VStack(spacing: 0) {
                    SavedTagFilterBar(
                        tags: appModel.currentSavedTagCounts,
                        selection: appModel.selectedSavedTag,
                        onSelect: appModel.selectSavedTag
                    )

                    SavedLinksListContent(onSavedLinkTap: openSavedLink)
                }
            }
        }
    }

    private func openSavedLink(_ save: MergedLatrSave) {
        Task {
            if let url = SavedLinkEmbedURL.previewURL(for: save) {
                openURL(url)
                return
            }
            if let entry = await appModel.savedLinkSocialEntry(for: save),
               let url = entry.canonicalURL {
                openURL(url)
                return
            }
            appModel.errorMessage = "Couldn't Find A Link For This Saved Story."
        }
    }

    private func openSembleItem(_ item: SembleCollectionItem) {
        appModel.selectedEntry = nil
        appModel.selectedSavedLink = nil
        appModel.selectedSembleItem = item
        sceneModel.navigate(to: .sembleItem(id: item.id), in: .saved)
    }
}
