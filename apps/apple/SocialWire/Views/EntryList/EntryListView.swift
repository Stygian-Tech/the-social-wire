import SwiftUI

struct EntryListView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.openURL) private var openURL
    var onEntryOpened: (() -> Void)? = nil
    @State private var refreshFeedback = 0
    @State private var saveFeedback = 0
    @State private var entryPendingTaggedSave: EntryListItem?

    var body: some View {
        Group {
            if appModel.filteredEntries.isEmpty,
               appModel.hasSelectedArticleFeed,
               (appModel.isLoadingEntries || appModel.sidebarFetching) {
                ReaderFeedLoadingView()
            } else if appModel.filteredEntries.isEmpty {
                ReaderFeedEmptyStateView(
                    isUnreadFilter: appModel.readerFilter == .unread,
                    action: emptyStateAction
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if appModel.readerListSource == .wire, let notice = appModel.wireFeedNotice {
                            Label(notice, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(notice)
                        }

                        Text("Articles")
                            .font(.title2.bold())
                            .frame(maxWidth: .infinity, alignment: .leading)

                        LazyVStack(spacing: 16) {
                            ForEach(appModel.filteredEntries) { entry in
                                Button {
                                    Task {
                                        await openEntry(entry)
                                    }
                                } label: {
                                    EntryRow(
                                        entry: entry,
                                        isRead: appModel.readAtByEntryId[entry.entryId] != nil,
                                        showsReadState: appModel.readerListSource.supportsReadState
                                    )
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                                .background(.thinMaterial, in: .rect(cornerRadius: 16))
                                .clipShape(.rect(cornerRadius: 16))
                                }
                                .buttonStyle(.plain)
                                .accessibilityElement(children: .combine)
                                .accessibilityValue(entryAccessibilityValue(entry))
                            .contextMenu {
                                if let websiteURL = entry.originalWebsiteURL {
                                    Button {
                                        Task {
                                            await appModel.recordExternalEntryOpen(entry)
                                            openURL(websiteURL)
                                        }
                                    } label: {
                                        Label("Open on Website", systemImage: "safari")
                                    }

                                    if EntryOpenTargetResolver.isRSSEntry(entry.entryId) {
                                        Button {
                                            Task {
                                                await openEntry(entry, rssModeOverride: .reader)
                                            }
                                        } label: {
                                            Label("Open in Native Reader", systemImage: "doc.richtext")
                                        }
                                    }
                                }

                                Button {
                                    saveFeedback += 1
                                    Task {
                                        await appModel.saveEntry(
                                            entryId: entry.entryId,
                                            url: entry.originalUrl.flatMap { URL(string: $0) },
                                            title: entry.title,
                                            excerpt: entry.summary
                                        )
                                    }
                                } label: {
                                    Label("Save", systemImage: "bookmark")
                                }

                                Button {
                                    entryPendingTaggedSave = entry
                                } label: {
                                    Label(
                                        appModel.isSembleReadLaterEnabled ? "Save With Note" : "Save With Tags",
                                        systemImage: appModel.isSembleReadLaterEnabled ? "note.text.badge.plus" : "tag"
                                    )
                                }

                                if appModel.readerListSource.supportsReadState {
                                    Button(appModel.readAtByEntryId[entry.entryId] == nil ? "Mark As Read" : "Mark As Unread") {
                                        Task { await appModel.toggleRead(entry) }
                                    }
                                }
                            }
                                .onAppear {
                                guard entry.entryId == appModel.filteredEntries.last?.entryId else {
                                    return
                                }
                                Task {
                                    await appModel.loadMoreSelectedFeedIfNeeded(
                                        triggeredByEntryId: entry.entryId
                                    )
                                }
                            }
                            }
                        }

                        if appModel.isLoadingMoreEntries {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding()
                    .frame(maxWidth: 700, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .refreshable {
            await appModel.refreshSelectedArticleFeed()
            refreshFeedback += 1
        }
        .sensoryFeedback(.impact(flexibility: .soft), trigger: refreshFeedback)
        .sensoryFeedback(.success, trigger: saveFeedback)
        .sheet(item: $entryPendingTaggedSave) { entry in
            if appModel.isSembleReadLaterEnabled {
                SembleNoteEditorSheet { note in
                    saveFeedback += 1
                    await appModel.saveEntry(
                        entryId: entry.entryId,
                        url: entry.originalUrl.flatMap { URL(string: $0) },
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
                        url: entry.originalUrl.flatMap { URL(string: $0) },
                        title: entry.title,
                        excerpt: entry.summary,
                        tags: tags
                    )
                }
            }
        }
    }

    private func emptyStateAction() {
        Task {
            if appModel.readerFilter == .unread {
                await appModel.applyReaderFilter(.all)
            } else {
                await appModel.refreshSelectedArticleFeed()
                refreshFeedback += 1
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

    private func entryAccessibilityValue(_ entry: EntryListItem) -> String {
        guard appModel.readerListSource.supportsReadState else {
            return entry.wireMetadata?.primaryReasonLabel ?? ""
        }
        return appModel.readAtByEntryId[entry.entryId] == nil ? "Unread" : "Read"
    }

}
