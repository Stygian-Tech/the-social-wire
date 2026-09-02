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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
                applyMode(mode)
            }
        }
        .onChange(of: mode) { _, newMode in
            applyMode(newMode)
        }
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
                    Group {
                        if dynamicTypeSize.isAccessibilitySize {
                            savedPicker.pickerStyle(.menu)
                        } else {
                            savedPicker.pickerStyle(.segmented)
                        }
                    }
                    .padding()

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

    private var savedPicker: some View {
        Picker("Saved", selection: $mode) {
            ForEach(SavedNewsMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if appModel.isSembleReadLaterEnabled, let item = appModel.selectedSembleItem {
            SembleItemDetailView(item: item)
        } else if !appModel.isSembleReadLaterEnabled, let save = appModel.selectedSavedLink {
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

    private func openSembleItem(_ item: SembleCollectionItem) {
        appModel.selectedEntry = nil
        appModel.selectedSavedLink = nil
        appModel.selectedSembleItem = item
        guard !usesPersistentDetail else { return }
        sceneModel.navigate(to: .sembleItem(id: item.id), in: .saved)
    }
}
