import SwiftUI

struct EntryListView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    var onOpenEntry: (() -> Void)?

    var body: some View {
        List {
            if appModel.isLoadingEntries && appModel.filteredEntries.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .readerClearListRow()
            } else if appModel.filteredEntries.isEmpty {
                ContentUnavailableView("No Articles", systemImage: "doc.text")
                    .readerClearListRow()
            } else {
                Section("Articles") {
                    ForEach(appModel.filteredEntries) { entry in
                        EntryRow(entry: entry, isRead: appModel.readAtByEntryId[entry.entryId] != nil)
                            .readerClearListRow()
                            .contentShape(Rectangle())
                            .onTapGesture {
                                Task {
                                    await appModel.selectEntry(entry)
                                    if appModel.selectedEntry?.entryId == entry.entryId {
                                        onOpenEntry?()
                                    }
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
