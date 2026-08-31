import SwiftUI

struct EntryListView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.openURL) private var openURL
    var onEntryOpened: (() -> Void)? = nil
    @State private var refreshFeedback = 0
    @State private var saveFeedback = 0
    @State private var entryPendingTaggedSave: EntryListItem?

    var body: some View {
        List {
            if appModel.readerListSource == .wire, let notice = appModel.wireFeedNotice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .readerClearListRow()
                    .accessibilityLabel(notice)
            }
            if appModel.filteredEntries.isEmpty,
               appModel.hasSelectedArticleFeed,
               (appModel.isLoadingEntries || appModel.sidebarFetching) {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .readerClearListRow()
            } else if appModel.filteredEntries.isEmpty {
                ContentUnavailableView(
                    appModel.wireFeedLoadFailed ? "The Wire Is Unavailable" : "No Articles",
                    systemImage: appModel.wireFeedLoadFailed ? "wifi.exclamationmark" : "doc.text"
                )
                    .readerClearListRow()
            } else {
                Section("Articles") {
                    ForEach(appModel.filteredEntries) { entry in
                        Button {
                            Task {
                                await openEntry(
                                    entry,
                                    forceNativeReader: false
                                )
                            }
                        } label: {
                            EntryRow(
                                entry: entry,
                                isRead: appModel.readAtByEntryId[entry.entryId] != nil,
                                showsReadState: appModel.readerListSource.supportsReadState
                            )
                                .readerFullWidthTapLabel()
                        }
                        .buttonStyle(.plain)
                        .readerClearListRow()
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

                                    Button {
                                        Task {
                                            await openEntry(
                                                entry,
                                                forceNativeReader: true
                                            )
                                        }
                                    } label: {
                                        Label("Open in Native Reader", systemImage: "doc.richtext")
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
                            .swipeActions(edge: .trailing, allowsFullSwipe: appModel.readerListSource.supportsReadState) {
                                if appModel.readerListSource.supportsReadState {
                                    Button(appModel.readAtByEntryId[entry.entryId] == nil ? "Read" : "Unread") {
                                        Task { await appModel.toggleRead(entry) }
                                    }
                                    .tint(.indigo)
                                }
                            }
                    }

                    if appModel.isLoadingMoreEntries {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .readerClearListRow()
                    }
                }
            }
        }
        .readerListCanvas()
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

    private func openEntry(
        _ entry: EntryListItem,
        forceNativeReader: Bool
    ) async {
        if !forceNativeReader,
           appModel.feedPreferences.articleOpenMode == .original,
           let websiteURL = entry.originalWebsiteURL {
            await appModel.recordExternalEntryOpen(entry)
            openURL(websiteURL)
            return
        }
        await appModel.selectEntry(entry)
        guard appModel.selectedEntry?.entryId == entry.entryId else { return }
        onEntryOpened?()
    }

    private func entryAccessibilityValue(_ entry: EntryListItem) -> String {
        guard appModel.readerListSource.supportsReadState else {
            return entry.wireMetadata?.primaryReasonLabel ?? ""
        }
        return appModel.readAtByEntryId[entry.entryId] == nil ? "Unread" : "Read"
    }

}
