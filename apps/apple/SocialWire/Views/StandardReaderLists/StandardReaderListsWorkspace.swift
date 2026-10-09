import SwiftUI

struct StandardReaderListsWorkspace: View {
    @Environment(SocialWireAppModel.self) private var appModel
    var usesExternalSidebar = false
    @State private var compactColumn = NavigationSplitViewColumn.sidebar
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var showingManagement = false
    @State private var pendingRemoval: StandardReaderList?
    @State private var feedback = 0
    @State private var openedEntryID: String?
    @State private var deferredReadEntryID: String?
    @State private var deferredReadViewerDID: String?
    @State private var entryOpenRevision = 0

    private var model: StandardReaderListsModel { appModel.standardReaderLists }

    var body: some View {
        workspaceColumns
        .task(id: appModel.viewerDID) { await model.load() }
        .sheet(isPresented: $showingManagement) {
            StandardReaderListsManagementView(model: model, publications: availablePublications)
        }
        .confirmationDialog("Remove List?", isPresented: Binding(
            get: { pendingRemoval != nil },
            set: { if !$0 { pendingRemoval = nil } }
        ), titleVisibility: .visible, presenting: pendingRemoval) { list in
            Button(list.owned ? "Delete List" : "Remove List", role: .destructive) {
                Task {
                    do {
                        if list.owned { try await model.delete(list) }
                        else { try await model.save(list, remove: true) }
                        feedback += 1
                    } catch { appModel.errorMessage = error.localizedDescription }
                }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { list in
            Text(list.owned ? "Delete \(list.name) from your PDS?" : "Remove \(list.name) from your saved lists?")
        }
        .sensoryFeedback(.success, trigger: feedback)
        .onChange(of: model.filter) { _, _ in
            entryOpenRevision += 1
            settleDeferredRead()
            openedEntryID = nil
            Task { await model.loadFeed() }
        }
        .onChange(of: model.selectedList?.uri) { _, _ in
            settleDeferredRead()
            entryOpenRevision += 1
        }
        .onChange(of: compactColumn) { previous, current in
            if previous == .detail, current != .detail {
                entryOpenRevision += 1
                settleDeferredRead()
            }
        }
        .onDisappear {
            entryOpenRevision += 1
            settleDeferredRead()
        }
        .onChange(of: appModel.viewerDID) { _, _ in
            deferredReadEntryID = nil
            deferredReadViewerDID = nil
            entryOpenRevision += 1
            openedEntryID = nil
            showingManagement = false
            pendingRemoval = nil
            compactColumn = .sidebar
        }
    }

    @ViewBuilder
    private var workspaceColumns: some View {
        if usesExternalSidebar {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                Group {
                    if model.selectedList == nil { listsColumn }
                    else { articlesColumn }
                }
                .navigationTitle(model.selectedList?.name ?? "Lists")
                .toolbar { managementButton }
            } detail: {
                readerColumn
            }
        } else {
            NavigationSplitView(preferredCompactColumn: $compactColumn) {
                listsColumn
                    .navigationTitle("Lists")
                    .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 340)
                    .toolbar { managementButton }
            } content: {
                articlesColumn
                    .navigationTitle(model.selectedList?.name ?? "Articles")
                    .navigationSplitViewColumnWidth(min: 260, ideal: 380, max: 520)
            } detail: {
                readerColumn
            }
        }
    }

    @ToolbarContentBuilder
    private var managementButton: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button("Manage Lists", systemImage: "plus") { showingManagement = true }
                .disabled(!model.signedIn)
                .accessibilityIdentifier("lists.manage")
        }
    }

    @ViewBuilder
    private var readerColumn: some View {
        if let entry = model.selectedEntry {
            EntryDetailView(entry: entry)
        } else if model.isLoadingEntry {
            ProgressView("Loading Article")
        } else if let error = model.entryError {
            ContentUnavailableView {
                Label("Article Could Not Load", systemImage: "exclamationmark.triangle")
            } description: { Text(error) } actions: {
                if let id = openedEntryID, let item = model.entries.first(where: { $0.entryId == id }) {
                    Button("Retry") { open(item) }
                }
            }
        } else {
            ContentUnavailableView("Select an Article", systemImage: "doc.text")
        }
    }

    private var listsColumn: some View {
        List {
            if !model.signedIn {
                ContentUnavailableView("Sign In to Use Lists", systemImage: "person.crop.circle")
            } else {
                if model.isLoading { ProgressView("Loading Lists") }
                if let error = model.error {
                    Text(error).font(.callout).foregroundStyle(.secondary)
                    Button("Retry") { Task { await model.load(refresh: true) } }
                }
                listSection("Your Lists", lists: model.lists.filter(\.owned))
                listSection("Saved Lists", lists: model.lists.filter { $0.saved && !$0.owned })
                if !model.isLoading, model.lists.isEmpty, model.error == nil {
                    ContentUnavailableView {
                        Label("No Lists Yet", systemImage: "list.bullet.rectangle")
                    } description: {
                        Text("Find a public list or create one with publications and creator accounts.")
                    } actions: {
                        Button("Add List") { showingManagement = true }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .refreshable { await model.load(refresh: true) }
        .accessibilityIdentifier("lists.navigation")
    }

    private func listSection(_ title: String, lists: [StandardReaderList]) -> some View {
        Section(title) {
            ForEach(lists) { list in
                Button {
                    openedEntryID = nil
                    compactColumn = .content
                    Task { await model.select(list) }
                } label: {
                    Label(list.name, systemImage: "list.bullet.rectangle")
                        .readerFullWidthTapLabel()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("lists.row.\(list.uri)")
                .accessibilityAddTraits(model.selectedList?.uri == list.uri ? .isSelected : [])
                .contextMenu {
                    if let url = StandardReaderListContract.shareURL(list.uri) {
                        ShareLink(item: url) { Label("Copy or Share Link", systemImage: "square.and.arrow.up") }
                    }
                    Button(list.owned ? "Delete List" : "Remove List", role: .destructive) {
                        pendingRemoval = list
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var articlesColumn: some View {
        if let selected = model.selectedList {
            @Bindable var listModel = model
            VStack(spacing: 0) {
                List {
                    if let description = selected.description, !description.isEmpty {
                        Text(description).font(.callout).foregroundStyle(.secondary)
                    }
                    if !(selected.publicationDetails ?? []).isEmpty || !selected.users.isEmpty {
                        DisclosureGroup("Sources") {
                            ForEach(selected.publicationDetails ?? [], id: \.publicationId) { source in
                                Text(source.title)
                            }
                            ForEach(selected.users, id: \.self) { user in Text(user).font(.caption) }
                        }
                    }
                    if let error = model.feedError {
                        Text(error).foregroundStyle(.secondary)
                        Button("Retry") { Task { await model.loadFeed() } }
                    }
                    ForEach(model.entries) { item in
                        Button {
                            open(item)
                        } label: {
                            ArticleListRow(model: rowModel(item))
                                .readerFullWidthTapLabel()
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("lists.entry.\(item.entryId)")
                        .task {
                            if item.entryId == model.entries.last?.entryId { await model.loadFeed(nextPage: true) }
                        }
                    }
                    if model.isLoadingFeed { ProgressView("Loading Articles") }
                    if model.cursor != nil && !model.isLoadingFeed {
                        Button("Load More") { Task { await model.loadFeed(nextPage: true) } }
                    }
                    if model.entries.isEmpty && !model.isLoadingFeed && model.feedError == nil {
                        ContentUnavailableView("No Articles", systemImage: "doc.text", description: Text("This list has no \(model.filter == .unread ? "unread " : "")articles yet."))
                    }
                }
                .refreshable {
                    entryOpenRevision += 1
                    settleDeferredRead()
                    await model.loadFeed()
                }
                Picker("Articles", selection: $listModel.filter) {
                    Text("All").tag(ReaderFilter.all)
                    Text("Unread").tag(ReaderFilter.unread)
                }
                .pickerStyle(.segmented)
                .padding()
            }
            .accessibilityIdentifier("lists.articles")
        } else {
            ContentUnavailableView("Select a List", systemImage: "list.bullet.rectangle")
        }
    }

    private func open(_ item: EntryListItem) {
        let viewer = appModel.viewerDID
        let listURI = model.selectedList?.uri
        entryOpenRevision += 1
        let revision = entryOpenRevision
        let previous = deferredReadViewerDID == viewer ? deferredReadEntryID : nil
        deferredReadEntryID = nil
        deferredReadViewerDID = nil
        openedEntryID = item.entryId
        compactColumn = .detail
        Task {
            guard appModel.viewerDID == viewer else { return }
            if let previous, previous != item.entryId {
                await appModel.markRead(for: .entry(entryId: previous))
            }
            guard appModel.viewerDID == viewer, model.selectedList?.uri == listURI,
                  entryOpenRevision == revision else { return }
            await model.openEntry(item)
            guard appModel.viewerDID == viewer, model.selectedEntry?.entryId == item.entryId,
                  entryOpenRevision == revision else { return }
            if model.filter == .unread {
                deferredReadEntryID = item.entryId
                deferredReadViewerDID = viewer
            } else {
                await appModel.markRead(for: .entry(entryId: item.entryId))
            }
        }
    }

    private func settleDeferredRead() {
        guard let entryID = deferredReadEntryID else { return }
        let viewer = deferredReadViewerDID
        deferredReadEntryID = nil
        deferredReadViewerDID = nil
        Task {
            guard viewer != nil, appModel.viewerDID == viewer else { return }
            await appModel.markRead(for: .entry(entryId: entryID))
        }
    }

    private func rowModel(_ item: EntryListItem) -> ArticleListRowModel {
        ArticleListRowModel(title: item.title, summary: item.summary, subtitle: item.displayPublishedAt,
            thumbnailURLs: [item.thumbnailUrl, item.thumbnailFallbackUrl].compactMap { $0.flatMap(URL.init(string:)) },
            publication: nil, reason: nil, reasonAccessibilityLabel: nil, tags: [],
            isRead: appModel.readAtByEntryId[item.entryId] != nil || item.isRead, showsReadState: true)
    }

    private var availablePublications: [StandardReaderListPublication] {
        var seen = Set<String>()
        return appModel.allPublicationRows.compactMap { publication in
            guard StandardReaderListContract.recordURI(publication.publicationId, collection: "site.standard.publication") != nil,
                  seen.insert(publication.publicationId).inserted else { return nil }
            return StandardReaderListPublication(publicationId: publication.publicationId, title: publication.title,
                authorDid: publication.authorDid, authorHandle: nil, iconUrl: nil, avatarUrl: nil)
        }
    }
}
