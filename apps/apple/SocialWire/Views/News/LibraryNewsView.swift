import SwiftUI

enum LibraryMode: String, CaseIterable, Identifiable, Hashable {
    case subscribed = "Subscribed"
    case following = "Following"
    case myPublications = "My Publications"

    var id: String { rawValue }
}

struct LibraryNewsView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let sceneModel: NewsSceneModel
    @State private var mode: LibraryMode = .subscribed
    @State private var presentedSheet: LibrarySheet?
    @State private var showingMarkAllReadConfirmation = false
    @State private var bulkReadFeedback = 0

    private var usesPersistentDetail: Bool {
        horizontalSizeClass != .compact
    }

    var body: some View {
        Group {
            if usesPersistentDetail {
                HStack(spacing: 0) {
                    sourceColumn
                        .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
                    Divider()
                    articlesColumn
                        .frame(minWidth: 320, idealWidth: 400, maxWidth: 480)
                    Divider()
                    readerColumn
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                sourceColumn
            }
        }
        .navigationTitle("Library")
        .toolbar {
            if bulkReadScope != .unavailable {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Mark All As Read") {
                            showingMarkAllReadConfirmation = true
                        }
                        Button("Mark All As Unread") {
                            Task {
                                await appModel.markUnread(for: bulkReadScope)
                                bulkReadFeedback += 1
                            }
                        }
                    } label: {
                        Label("Read State", systemImage: "checkmark.circle")
                    }
                }
            }
        }
        .alert("Mark All As Read?", isPresented: $showingMarkAllReadConfirmation) {
            Button("Mark All As Read") {
                Task {
                    await appModel.markRead(for: bulkReadScope)
                    bulkReadFeedback += 1
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This marks every cached article in \(mode.rawValue) as read on your account.")
        }
        .sensoryFeedback(.success, trigger: bulkReadFeedback)
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .addPublication:
                AddPublicationView()
            case .newFolder:
                NewFolderView()
            }
        }
        .task {
            if appModel.selectedSidebar == .myPublications {
                mode = .myPublications
            }
            configureSource(for: mode)
        }
        .onChange(of: mode) { _, newMode in
            configureSource(for: newMode)
        }
        .onChange(of: appModel.selectedSidebar) { _, selection in
            if selection == .myPublications {
                mode = .myPublications
            }
        }
    }

    private var sourceColumn: some View {
        VStack(spacing: 0) {
            Picker("Library", selection: $mode) {
                ForEach(LibraryMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            Group {
                switch mode {
                case .subscribed:
                    List {
                        SubscribedPublicationSidebarTree(
                            showingNewFolder: sheetBinding(for: .newFolder),
                            showingAddPublication: sheetBinding(for: .addPublication),
                            onPublicationTap: openPublication
                        )
                    }
                    .readerListCanvas()
                case .following:
                    List {
                        FollowingPublicationSidebarTree(onPublicationTap: openPublication)
                    }
                    .readerListCanvas()
                case .myPublications:
                    LibraryPublicationList(
                        publications: appModel.myPublications,
                        onPublicationTap: openPublication
                    )
                }
            }
        }
        .refreshable {
            await appModel.refreshSidebarProjection()
        }
    }

    @ViewBuilder
    private var articlesColumn: some View {
        if appModel.selectedPublication != nil || appModel.hasSelectedArticleFeed {
            EntryListView()
        } else if appModel.sidebarFetching {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "Select a Publication",
                systemImage: "newspaper",
                description: Text("Choose a publication to browse its latest stories.")
            )
        }
    }

    @ViewBuilder
    private var readerColumn: some View {
        if let entry = appModel.selectedEntry {
            EntryDetailView(entry: entry)
        } else {
            ContentUnavailableView(
                "Select an Article",
                systemImage: "doc.text",
                description: Text("Choose an article, then read it here or open the publisher's website.")
            )
        }
    }

    private func openPublication(_ publication: DiscoveredPublication) {
        Task {
            await appModel.selectPublication(publication)
            guard appModel.selectedPublication?.publicationId == publication.publicationId else { return }
            if !usesPersistentDetail {
                sceneModel.navigate(to: .publication(id: publication.publicationId), in: .library)
            }
        }
    }

    private func configureSource(for mode: LibraryMode) {
        switch mode {
        case .subscribed:
            appModel.selectReaderListSource(.subscribed)
        case .following:
            appModel.selectReaderListSource(.following)
        case .myPublications:
            appModel.openMyPublications()
        }
    }

    private var bulkReadScope: ReaderMarkReadScope {
        switch mode {
        case .subscribed:
            .list(.subscribed)
        case .following:
            .list(.following)
        case .myPublications:
            .unavailable
        }
    }

    private func sheetBinding(for sheet: LibrarySheet) -> Binding<Bool> {
        Binding(
            get: { presentedSheet == sheet },
            set: { isPresented in
                presentedSheet = isPresented ? sheet : nil
            }
        )
    }
}

private enum LibrarySheet: String, Identifiable, Equatable {
    case addPublication
    case newFolder

    var id: String { rawValue }
}

private struct LibraryPublicationList: View {
    let publications: [DiscoveredPublication]
    let onPublicationTap: (DiscoveredPublication) -> Void

    var body: some View {
        List {
            if publications.isEmpty {
                ContentUnavailableView(
                    "No Publications",
                    systemImage: "newspaper",
                    description: Text("Publications you author will appear here.")
                )
                .readerClearListRow()
            } else {
                ForEach(publications) { publication in
                    Button {
                        onPublicationTap(publication)
                    } label: {
                        HStack(spacing: 12) {
                            PublicationAvatar(publication: publication, size: 42)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(publication.title)
                                    .font(.headline)
                                Text(publication.authorHandle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .readerFullWidthTapLabel()
                    }
                    .buttonStyle(.plain)
                    .readerClearListRow()
                    .contextMenu {
                        FolderAssignmentMenu(publication: publication)
                    }
                }
            }
        }
        .readerListCanvas()
    }
}
