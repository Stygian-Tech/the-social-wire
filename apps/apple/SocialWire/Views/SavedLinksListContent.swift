import SwiftUI

struct SavedLinksListContent: View {
    @Environment(SocialWireAppModel.self) private var appModel
    var onSavedLinkTap: ((MergedLatrSave) -> Void)? = nil
    @State private var savePendingDelete: MergedLatrSave?
    @State private var tagEditorSave: MergedLatrSave?
    @State private var deleteFeedback = 0

    private var isArchivedView: Bool {
        appModel.readerListSource == .archive
    }

    var body: some View {
        List {
            Section {
                if appModel.filteredCurrentSavedLinks.isEmpty {
                    ContentUnavailableView(
                        isArchivedView ? "Nothing Archived Yet" : "Nothing Queued Yet",
                        systemImage: isArchivedView ? "archivebox" : "bookmark",
                        description: Text(
                            isArchivedView
                                ? "Archived read-later links will appear here."
                                : "Save an article from the toolbar or article list to queue it here."
                        )
                    )
                    .readerClearListRow()
                } else {
                    ForEach(appModel.filteredCurrentSavedLinks) { save in
                        savedLinkButton(for: save)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .readerClearListRow()
                        .contextMenu {
                            Button("Edit Tags") {
                                tagEditorSave = save
                            }
                            if !save.tags.isEmpty {
                                Button("Clear Tags") {
                                    Task { await appModel.clearTags(on: save) }
                                }
                            }
                            if isArchivedView {
                                Button("Unarchive") {
                                    Task { await appModel.unarchive(save) }
                                }
                            } else {
                                Button("Archive") {
                                    Task { await appModel.archive(save) }
                                }
                            }
                            Button("Delete", role: .destructive) {
                                savePendingDelete = save
                            }
                        }
                        .swipeActions {
                            if isArchivedView {
                                Button("Unarchive") {
                                    Task { await appModel.unarchive(save) }
                                }
                                .tint(.indigo)
                            } else {
                                Button("Archive") {
                                    Task { await appModel.archive(save) }
                                }
                                .tint(.orange)
                            }
                            Button("Delete", role: .destructive) {
                                savePendingDelete = save
                            }
                        }
                    }
                }
            } header: {
                if !isArchivedView {
                    Text(appModel.readerListSource.rawValue)
                        .font(.title2.bold())
                        .textCase(nil)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.bottom, 16, for: .scrollContent)
        .task(id: appModel.readerListSource) {
            await appModel.refreshSavedLinks()
        }
        .confirmationDialog(
            "Delete saved link?",
            isPresented: Binding(
                get: { savePendingDelete != nil },
                set: { if !$0 { savePendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: savePendingDelete
        ) { save in
            Button("Delete", role: .destructive) {
                Task {
                    await appModel.delete(save)
                    deleteFeedback += 1
                }
                savePendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                savePendingDelete = nil
            }
        } message: { save in
            Text("This removes \"\(save.title)\" from \(isArchivedView ? "Archive" : "Read Later").")
        }
        .sensoryFeedback(.success, trigger: deleteFeedback)
        .sheet(item: $tagEditorSave) { save in
            SavedTagEditorSheet(
                title: "Edit Tags",
                initialTags: save.tags,
                suggestions: appModel.currentSavedTagCounts.map(\.tag)
            ) { tags in
                await appModel.replaceTags(on: save, with: tags)
            }
        }
    }

    @ViewBuilder
    private func savedLinkButton(for save: MergedLatrSave) -> some View {
        let row = SavedLinkRow(
            save: save,
            isSelected: appModel.selectedSavedLink?.id == save.id
        )
        if isArchivedView {
            Button {
                open(save)
            } label: {
                row
            }
            .buttonStyle(.plain)
        } else {
            ArticleListCard(action: { open(save) }) {
                row
            }
        }
    }

    private func open(_ save: MergedLatrSave) {
        if let onSavedLinkTap {
            onSavedLinkTap(save)
        } else {
            appModel.selectedSavedLink = save
        }
    }
}
