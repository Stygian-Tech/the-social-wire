import SwiftUI

struct SavedNewsView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    let sceneModel: NewsSceneModel
    @State private var showingTagManagement = false

    var body: some View {
        SavedNewsContent(onSavedLinkTap: openSavedLink, onSembleItemTap: openSembleItem)
        .navigationTitle(appModel.readerListSource == .archive ? "Archive" : appModel.savedTabTitle)
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

    private func openSavedLink(_ save: MergedLatrSave) {
        appModel.selectedEntry = nil
        appModel.selectedSembleItem = nil
        appModel.selectedSavedLink = save
        sceneModel.navigate(to: .savedLink(id: save.id), in: .saved)
    }

    private func openSembleItem(_ item: SembleCollectionItem) {
        appModel.selectedEntry = nil
        appModel.selectedSavedLink = nil
        appModel.selectedSembleItem = item
        sceneModel.navigate(to: .sembleItem(id: item.id), in: .saved)
    }
}
