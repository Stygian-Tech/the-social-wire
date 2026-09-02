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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let sceneModel: NewsSceneModel
    @State private var mode: LibraryMode = .subscribed
    @State private var presentedSheet: LibrarySheet?

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
                    FeedMarkReadButton(
                        contextID: "\(appModel.viewerDID ?? ""):library:\(bulkReadScope)",
                        refreshRevision: appModel.readAgeRevision,
                        scopeTitle: bulkReadTitle,
                        loadOptions: { try await appModel.readAgeOptions(for: bulkReadScope) },
                        markAllRead: { await appModel.markRead(for: bulkReadScope) },
                        markOlderRead: { try await appModel.markRead(for: bulkReadScope, before: $0.before) },
                        markAllUnread: { await appModel.markUnread(for: bulkReadScope) }
                    )
                }
            }
        }
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
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    libraryPicker.pickerStyle(.menu)
                } else {
                    libraryPicker.pickerStyle(.segmented)
                }
            }
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

    private var libraryPicker: some View {
        Picker("Library", selection: $mode) {
            ForEach(LibraryMode.allCases) { mode in
                Text(mode == .myPublications && !dynamicTypeSize.isAccessibilitySize ? "Mine" : mode.rawValue)
                    .accessibilityLabel(mode.rawValue)
                    .tag(mode)
            }
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
        guard mode != .myPublications else { return .unavailable }
        if usesPersistentDetail {
            return ReaderMarkReadScope.selectedFeed(appModel.feedSelection)
        }
        return .list(mode == .following ? .following : .subscribed)
    }

    private var bulkReadTitle: String {
        switch bulkReadScope {
        case .publication(let id):
            return appModel.publication(forId: id)?.title ?? "This Publication"
        case .folder(let key):
            return appModel.folders.first { $0.uri.hasSuffix("/\(key)") }?.value.name ?? "This Folder"
        default:
            return mode.rawValue
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
