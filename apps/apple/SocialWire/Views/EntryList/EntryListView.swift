import SwiftUI

struct EntryListView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    var navigationEpoch: (() -> UInt)? = nil
    var onEntryOpened: ((UInt) -> Void)? = nil
    @State private var refreshFeedback = 0
    @State private var saveFeedback = 0

    var body: some View {
        List {
            if appModel.filteredEntries.isEmpty,
               appModel.hasSelectedArticleFeed,
               (appModel.isLoadingEntries || appModel.sidebarFetching) {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .readerClearListRow()
            } else if appModel.filteredEntries.isEmpty {
                ContentUnavailableView("No Articles", systemImage: "doc.text")
                    .readerClearListRow()
            } else {
                Section("Articles") {
                    ForEach(appModel.filteredEntries) { entry in
                        Button {
                            let epoch = navigationEpoch?() ?? 0
                            Task { await openEntry(entry, navigationEpoch: epoch) }
                        } label: {
                            EntryRow(entry: entry, isRead: appModel.readAtByEntryId[entry.entryId] != nil)
                                .readerFullWidthTapLabel()
                        }
                        .buttonStyle(.plain)
                        .readerClearListRow()
                        .accessibilityElement(children: .combine)
                        .accessibilityValue(appModel.readAtByEntryId[entry.entryId] == nil ? "Unread" : "Read")
                            .contextMenu {
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

                                Button(appModel.readAtByEntryId[entry.entryId] == nil ? "Mark As Read" : "Mark As Unread") {
                                    Task { await appModel.toggleRead(entry) }
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
                            .swipeActions(edge: .trailing) {
                                Button(appModel.readAtByEntryId[entry.entryId] == nil ? "Read" : "Unread") {
                                    Task { await appModel.toggleRead(entry) }
                                }
                                .tint(.indigo)
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
    }

    private func openEntry(_ entry: EntryListItem, navigationEpoch: UInt) async {
        await appModel.selectEntry(entry)
        guard appModel.selectedEntry?.entryId == entry.entryId else { return }
        onEntryOpened?(navigationEpoch)
    }

}
