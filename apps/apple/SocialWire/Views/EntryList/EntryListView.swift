import SwiftUI

struct EntryListView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.openURL) private var openURL

    var onEntryOpened: (() -> Void)? = nil

    @State private var refreshFeedback = 0
    @State private var saveFeedback = 0
    @State private var entryPendingTaggedSave: EntryListItem?

    var body: some View {
        let visibleEntries = appModel.filteredEntries
        EntryListStateView(
            isEmpty: visibleEntries.isEmpty,
            isLoading: appModel.isLoadingEntries || appModel.sidebarFetching,
            hasSelectedFeed: appModel.hasSelectedArticleFeed,
            isUnreadFilter: appModel.readerFilter == .unread,
            notice: appModel.readerListSource == .wire ? appModel.wireFeedNotice : nil,
            entries: visibleEntries,
            readAtByEntryId: appModel.readAtByEntryId,
            showsReadState: appModel.readerListSource.supportsReadState,
            isLoadingMore: appModel.isLoadingMoreEntries,
            isSembleReadLaterEnabled: appModel.isSembleReadLaterEnabled,
            onOpen: openEntryFromRow,
            onOpenWebsite: openWebsite,
            onOpenInReader: openInNativeReader,
            onSave: save,
            onSaveWithMetadata: { entryPendingTaggedSave = $0 },
            onToggleRead: toggleRead,
            onLastEntryAppear: loadMore,
            onEmptyAction: emptyStateAction
        )
        .refreshable {
            await refresh()
        }
        .sensoryFeedback(.impact(flexibility: .soft), trigger: refreshFeedback)
        .sensoryFeedback(.success, trigger: saveFeedback)
        .sheet(item: $entryPendingTaggedSave) { entry in
            taggedSaveSheet(entry)
        }
    }

    private func refresh() async {
        await appModel.refreshSelectedArticleFeed()
        refreshFeedback += 1
    }

    private func emptyStateAction() {
        Task {
            if appModel.readerFilter == .unread {
                await appModel.applyReaderFilter(.all)
            } else {
                await refresh()
            }
        }
    }

    private func openEntryFromRow(_ entry: EntryListItem) {
        Task { await openEntry(entry) }
    }

    private func openWebsite(_ entry: EntryListItem) {
        guard let websiteURL = entry.originalWebsiteURL else { return }
        Task {
            await appModel.recordExternalEntryOpen(entry)
            openURL(websiteURL)
        }
    }

    private func openInNativeReader(_ entry: EntryListItem) {
        Task { await openEntry(entry, rssModeOverride: .reader) }
    }

    private func save(_ entry: EntryListItem) {
        saveFeedback += 1
        Task {
            await appModel.saveEntry(
                entryId: entry.entryId,
                url: entry.originalUrl.flatMap(URL.init(string:)),
                title: entry.title,
                excerpt: entry.summary
            )
        }
    }

    private func toggleRead(_ entry: EntryListItem) {
        Task { await appModel.toggleRead(entry) }
    }

    private func loadMore(_ entry: EntryListItem) {
        Task {
            await appModel.loadMoreSelectedFeedIfNeeded(triggeredByEntryId: entry.entryId)
        }
    }

    @ViewBuilder
    private func taggedSaveSheet(_ entry: EntryListItem) -> some View {
        if appModel.isSembleReadLaterEnabled {
            SembleNoteEditorSheet { note in
                saveFeedback += 1
                await appModel.saveEntry(
                    entryId: entry.entryId,
                    url: entry.originalUrl.flatMap(URL.init(string:)),
                    title: entry.title,
                    excerpt: entry.summary,
                    note: note
                )
            }
        } else {
            SavedTagEditorSheet(
                title: "Save With Tags",
                initialTags: [],
                suggestions: appModel.currentSavedTagCounts.map(\.tag)
            ) { tags in
                saveFeedback += 1
                await appModel.saveEntry(
                    entryId: entry.entryId,
                    url: entry.originalUrl.flatMap(URL.init(string:)),
                    title: entry.title,
                    excerpt: entry.summary,
                    tags: tags
                )
            }
        }
    }

    private func openEntry(
        _ entry: EntryListItem,
        rssModeOverride: ArticleOpenMode? = nil
    ) async {
        let rssMode = rssModeOverride ?? appModel.feedPreferences.articleOpenMode
        var target = EntryOpenTargetResolver.resolve(
            entryId: entry.entryId,
            originalURL: entry.originalUrl,
            rssArticleOpenMode: rssMode
        )

        if target == nil {
            await appModel.selectEntry(entry)
            target = EntryOpenTargetResolver.resolve(
                entryId: entry.entryId,
                originalURL: appModel.selectedEntry?.originalUrl,
                rssArticleOpenMode: rssMode
            )
        }

        switch target {
        case .external(let websiteURL):
            await appModel.recordExternalEntryOpen(entry)
            openURL(websiteURL)
        case .nativeRSS:
            if appModel.selectedEntry?.entryId != entry.entryId {
                await appModel.selectEntry(entry)
            }
            guard appModel.selectedEntry?.entryId == entry.entryId else { return }
            onEntryOpened?()
        case nil:
            appModel.errorMessage = "Couldn't Find A Link For This Article."
        }
    }
}

private struct EntryListStateView: View {
    let isEmpty: Bool
    let isLoading: Bool
    let hasSelectedFeed: Bool
    let isUnreadFilter: Bool
    let notice: String?
    let entries: [EntryListItem]
    let readAtByEntryId: [String: Date]
    let showsReadState: Bool
    let isLoadingMore: Bool
    let isSembleReadLaterEnabled: Bool
    let onOpen: (EntryListItem) -> Void
    let onOpenWebsite: (EntryListItem) -> Void
    let onOpenInReader: (EntryListItem) -> Void
    let onSave: (EntryListItem) -> Void
    let onSaveWithMetadata: (EntryListItem) -> Void
    let onToggleRead: (EntryListItem) -> Void
    let onLastEntryAppear: (EntryListItem) -> Void
    let onEmptyAction: () -> Void

    var body: some View {
        Group {
            if isEmpty, hasSelectedFeed, isLoading {
                ReaderFeedLoadingView()
            } else if isEmpty {
                ReaderFeedEmptyStateView(isUnreadFilter: isUnreadFilter, action: onEmptyAction)
            } else {
                EntryListScrollContent(
                    notice: notice,
                    entries: entries,
                    readAtByEntryId: readAtByEntryId,
                    showsReadState: showsReadState,
                    isLoadingMore: isLoadingMore,
                    isSembleReadLaterEnabled: isSembleReadLaterEnabled,
                    onOpen: onOpen,
                    onOpenWebsite: onOpenWebsite,
                    onOpenInReader: onOpenInReader,
                    onSave: onSave,
                    onSaveWithMetadata: onSaveWithMetadata,
                    onToggleRead: onToggleRead,
                    onLastEntryAppear: onLastEntryAppear
                )
            }
        }
    }
}

private struct EntryListScrollContent: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let notice: String?
    let entries: [EntryListItem]
    let readAtByEntryId: [String: Date]
    let showsReadState: Bool
    let isLoadingMore: Bool
    let isSembleReadLaterEnabled: Bool
    let onOpen: (EntryListItem) -> Void
    let onOpenWebsite: (EntryListItem) -> Void
    let onOpenInReader: (EntryListItem) -> Void
    let onSave: (EntryListItem) -> Void
    let onSaveWithMetadata: (EntryListItem) -> Void
    let onToggleRead: (EntryListItem) -> Void
    let onLastEntryAppear: (EntryListItem) -> Void

    var body: some View {
        ArticleListLayout(notice: notice, spacing: sectionSpacing) {
            #if os(macOS)
            ForEach(ArticleFeedRhythm.sections(for: entries)) { section in
                rhythmSection(section)
            }
            #else
            ForEach(entries) { entry in
                card(for: entry, style: .row)
            }
            #endif

            if isLoadingMore {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var sectionSpacing: CGFloat {
        #if os(macOS)
        24
        #else
        16
        #endif
    }

    #if os(macOS)
    @ViewBuilder
    private func rhythmSection(_ section: ArticleFeedSection<EntryListItem>) -> some View {
        switch section.style {
        case .lead:
            ForEach(section.items) { card(for: $0, style: .lead) }
        case .grid:
            // At accessibility sizes a card needs the whole measure, so demand a
            // minimum width the band can never fit twice.
            EditorialCardLayout(
                spacing: 18,
                minimumCardWidth: dynamicTypeSize.isAccessibilitySize
                    ? ArticleReadingWidth.feed
                    : 300
            ) {
                ForEach(section.items) { card(for: $0, style: .grid) }
            }
        case .row:
            VStack(alignment: .leading, spacing: 12) {
                ForEach(section.items) { card(for: $0, style: .row) }
            }
        }
    }
    #endif

    private func card(for entry: EntryListItem, style: ArticleFeedCardStyle) -> some View {
        EntryListCard(
            entry: entry,
            isRead: readAtByEntryId[entry.entryId] != nil,
            showsReadState: showsReadState,
            metadataSaveTitle: isSembleReadLaterEnabled ? "Save With Note" : "Save With Tags",
            metadataSaveSystemImage: isSembleReadLaterEnabled ? "note.text.badge.plus" : "tag",
            style: style,
            onOpen: { onOpen(entry) },
            onOpenWebsite: entry.originalWebsiteURL == nil ? nil : { onOpenWebsite(entry) },
            onOpenInReader: entry.originalWebsiteURL != nil && EntryOpenTargetResolver.isRSSEntry(entry.entryId)
                ? { onOpenInReader(entry) }
                : nil,
            onSave: { onSave(entry) },
            onSaveWithMetadata: { onSaveWithMetadata(entry) },
            onToggleRead: { onToggleRead(entry) },
            onAppear: {
                guard entry.entryId == entries.last?.entryId else { return }
                onLastEntryAppear(entry)
            }
        )
    }
}
