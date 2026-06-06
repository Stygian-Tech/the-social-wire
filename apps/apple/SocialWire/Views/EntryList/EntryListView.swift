import SwiftUI

struct EntryListView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    var navigationEpoch: (() -> UInt)? = nil
    var onEntryOpened: ((UInt) -> Void)? = nil

    var body: some View {
        List {
            if appModel.filteredEntries.isEmpty,
               appModel.selectedPublication != nil,
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
                            .contextMenu {
                                Button {
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
                                guard entry.entryId == appModel.filteredEntries.last?.entryId,
                                      let publication = appModel.selectedPublication
                                else { return }
                                Task { await appModel.loadMoreEntriesIfNeeded(for: publication) }
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
        .task(id: unreadChaseTaskKey) {
            guard appModel.readerFilter == .unread,
                  appModel.filteredEntries.isEmpty,
                  let publication = appModel.selectedPublication
            else { return }
            await appModel.chaseUnreadPagesIfNeeded(for: publication)
        }
        .refreshable {
            if let publication = appModel.selectedPublication {
                await appModel.loadEntries(for: publication)
            }
        }
    }

    private func openEntry(_ entry: EntryListItem, navigationEpoch: UInt) async {
        await appModel.selectEntry(entry)
        guard appModel.selectedEntry?.entryId == entry.entryId else { return }
        onEntryOpened?(navigationEpoch)
    }

    private var unreadChaseTaskKey: String {
        [
            appModel.readerFilter.rawValue,
            appModel.selectedPublication?.publicationId ?? "",
            String(appModel.entries.count),
            String(appModel.canLoadMoreEntries),
            String(appModel.filteredEntries.count),
        ].joined(separator: "|")
    }
}
