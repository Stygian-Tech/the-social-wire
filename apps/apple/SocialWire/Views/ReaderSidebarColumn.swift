import SwiftUI

/// iPad / regular sidebar: lists picker plus publications for the active source.
struct ReaderSidebarColumn: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Binding var showingNewFolder: Bool
    @Binding var showingAddPublication: Bool

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
            ForEach(ReaderListSource.allCases) { source in
                Button {
                    appModel.selectReaderListSource(source)
                } label: {
                    HStack {
                        Label(source.rawValue, systemImage: source.systemImage)
                        Spacer(minLength: 8)
                        if appModel.readerListSource == source {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .readerFullWidthTapLabel()
                }
                .buttonStyle(.plain)
                .readerClearListRow()
            }
        } header: {
            Text("Lists")
        }
    }

    private var savedLinksSidebarList: some View {
        List {
            listsSection
            Section {
                if appModel.currentSavedLinks.isEmpty {
                    Text(appModel.readerListSource == .archive ? "Nothing archived yet." : "Nothing queued yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .readerClearListRow()
                } else {
                    ForEach(appModel.currentSavedLinks) { save in
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
                                Task { await appModel.delete(save) }
                            }
                        }
                    }
                }
            } header: {
                Text(appModel.readerListSource == .archive ? "Archive" : "Read Later")
            }
        }
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
