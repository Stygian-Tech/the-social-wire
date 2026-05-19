import SwiftUI

/// iPad / regular sidebar: lists picker plus publications for the active source.
struct ReaderSidebarColumn: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Binding var showingNewFolder: Bool
    @Binding var showingAddPublication: Bool

    var body: some View {
        Group {
            if appModel.readerListSource == .readLater {
                readLaterSidebarList
            } else {
                publicationSidebarList
            }
        }
        .listStyle(.sidebar)
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
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Lists")
        }
    }

    private var readLaterSidebarList: some View {
        List {
            listsSection
            Section {
                if appModel.readLaterLatrConfigured {
                    if appModel.savedLinks.isEmpty {
                        Text("Nothing queued yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appModel.savedLinks) { save in
                            Button {
                                appModel.selectedSavedLink = save
                            } label: {
                                SavedLinkRow(save: save)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    Text("Configure L@tr Link in Profile → Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Read Later")
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
