import SwiftUI

/// iPad / regular sidebar: lists picker plus publications for the active source.
struct ReaderSidebarColumn: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Binding var showingNewFolder: Bool
    @Binding var showingAddPublication: Bool
    @State private var savePendingDelete: MergedLatrSave?
    @State private var deleteFeedback = 0

    var body: some View {
        Group {
            if appModel.readerListSource == .readLater || appModel.readerListSource == .archive {
                savedLinksSidebarList
            } else {
                publicationSidebarList
            }
        }
        .listStyle(.sidebar)
        .readerListCanvas()
    }

    private var listsSection: some View {
        Section {
            ForEach(appModel.visibleReaderListSources) { source in
                Button {
                    appModel.selectReaderListSource(source)
                } label: {
                    HStack {
                        Label(source.rawValue, systemImage: source.systemImage)
                        Spacer(minLength: 8)
                        if appModel.showTopLevelFeedUnreadCounts {
                            SidebarCountLabel(
                                count: appModel.topLevelUnreadCount(for: source),
                                accessibilityDescription: "unread articles"
                            )
                        }
                        if appModel.isTopLevelFeedSelected(source) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                                .accessibilityHidden(true)
                        }
                    }
                    .readerFullWidthTapLabel()
                }
                .buttonStyle(.plain)
                .readerClearListRow()
                .accessibilityAddTraits(appModel.isTopLevelFeedSelected(source) ? .isSelected : [])
            }
        } header: {
            Text("Lists")
        }
    }

    private var savedLinksSidebarList: some View {
        List {
            listsSection
            if !appModel.currentSavedFeedSources.isEmpty {
                Section("Publications") {
                    ForEach(appModel.currentSavedFeedSources) { source in
                        Button {
                            appModel.selectSavedFeedSource(source)
                        } label: {
                            HStack {
                                SavedLinkPublicationChip(model: source.model)
                                Spacer(minLength: 8)
                                SidebarCountLabel(
                                    count: source.count,
                                    accessibilityDescription: "saved articles"
                                )
                            }
                            .readerFullWidthTapLabel()
                        }
                        .buttonStyle(.plain)
                        .readerClearListRow()
                        .accessibilityAddTraits(
                            appModel.selectedSavedSourceKey == source.id
                                ? .isSelected
                                : []
                        )
                    }
                }
            }
            Section {
                if appModel.filteredCurrentSavedLinks.isEmpty {
                    Text(appModel.readerListSource == .archive ? "Nothing archived yet." : "Nothing queued yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .readerClearListRow()
                } else {
                    ForEach(appModel.filteredCurrentSavedLinks) { save in
                        Button {
                            appModel.selectedSavedLink = save
                        } label: {
                            SavedLinkRow(
                                save: save,
                                isSelected: appModel.selectedSavedLink?.id == save.id
                            )
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .readerClearListRow()
                        .contextMenu {
                            if appModel.readerListSource == .archive {
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
                    }
                }
            } header: {
                Text(appModel.readerListSource == .archive ? "Archive" : "Read Later")
            }
        }
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
            Text("This removes \"\(save.title)\" from \(appModel.readerListSource == .archive ? "Archive" : "Read Later").")
        }
        .sensoryFeedback(.success, trigger: deleteFeedback)
    }

    private var publicationSidebarList: some View {
        @Bindable var model = appModel

        return List(selection: $model.selectedSidebar) {
            listsSection
            if appModel.readerListSource == .subscribed {
                SubscribedPublicationSidebarTree(
                    showingNewFolder: $showingNewFolder,
                    showingAddPublication: $showingAddPublication
                )
            } else if appModel.readerListSource == .following {
                FollowingPublicationSidebarTree()
            }
        }
    }
}
