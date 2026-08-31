import SwiftUI

enum SavedNewsMode: String, CaseIterable, Identifiable, Hashable {
    case readLater = "Read Later"
    case archive = "Archive"

    var id: String { rawValue }

    var readerListSource: ReaderListSource {
        switch self {
        case .readLater: .readLater
        case .archive: .archive
        }
    }
}

struct SavedNewsView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let sceneModel: NewsSceneModel
    @State private var mode: SavedNewsMode = .readLater
    @State private var showingTagManagement = false

    private var usesPersistentDetail: Bool {
        horizontalSizeClass != .compact
    }

    var body: some View {
        Group {
            if usesPersistentDetail {
                HStack(spacing: 0) {
                    savedList
                        .frame(minWidth: 320, idealWidth: 430, maxWidth: 520)
                    Divider()
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                savedList
            }
        }
        .navigationTitle("Saved")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingTagManagement = true
                } label: {
                    Label("Manage Tags", systemImage: "tag")
                }
            }
        }
        .sheet(isPresented: $showingTagManagement) {
            SavedTagManagementView()
        }
        .task {
            applyMode(mode)
        }
        .onChange(of: mode) { _, newMode in
            applyMode(newMode)
        }
    }

    private var savedList: some View {
        VStack(spacing: 0) {
            Picker("Saved", selection: $mode) {
                ForEach(SavedNewsMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            SavedTagFilterBar(
                tags: appModel.currentSavedTagCounts,
                selection: appModel.selectedSavedTag,
                onSelect: appModel.selectSavedTag
            )

            SavedLinksListContent(onSavedLinkTap: openSavedLink)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let save = appModel.selectedSavedLink {
            SavedLinkDetailView(save: save)
        } else {
            ContentUnavailableView(
                "Select a Saved Story",
                systemImage: "bookmark",
                description: Text("Saved stories open as their publisher presented them on the web.")
            )
        }
    }

    private func applyMode(_ mode: SavedNewsMode) {
        appModel.selectReaderListSource(mode.readerListSource)
    }

    private func openSavedLink(_ save: MergedLatrSave) {
        appModel.selectedEntry = nil
        appModel.selectedSavedLink = save
        guard !usesPersistentDetail else { return }
        sceneModel.navigate(to: .savedLink(id: save.id), in: .saved)
    }
}
