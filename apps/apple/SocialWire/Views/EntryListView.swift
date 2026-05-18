import SwiftUI

struct EntryListView: View {
    @Environment(SocialWireAppModel.self) private var appModel

    /// Hides the navigation bar (filter + title) when an article is presented full-width on compact width.
    var hidesNavigationChrome: Bool

    init(hidesNavigationChrome: Bool = false) {
        self.hidesNavigationChrome = hidesNavigationChrome
    }

    var body: some View {
        @Bindable var model = appModel

        List {
            if appModel.isLoadingEntries {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else if appModel.filteredEntries.isEmpty {
                ContentUnavailableView("No Articles", systemImage: "doc.text")
            } else {
                ForEach(appModel.filteredEntries) { entry in
                    EntryRow(entry: entry, isRead: appModel.readAtByEntryId[entry.entryId] != nil)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            Task { await appModel.selectEntry(entry) }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(appModel.readAtByEntryId[entry.entryId] == nil ? "Read" : "Unread") {
                                Task { await appModel.toggleRead(entry) }
                            }
                            .tint(.indigo)
                        }
                }
            }
        }
        .navigationTitle(appModel.selectedPublication?.title ?? "Articles")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Filter", selection: Binding(
                    get: { model.readerFilter },
                    set: { newValue in Task { await model.applyReaderFilter(newValue) } }
                )) {
                    ForEach(ReaderFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
            }
            ToolbarItem(placement: .topBarTrailing) {
                if let publication = appModel.selectedPublication {
                    Button {
                        Task { await appModel.loadEntries(for: publication) }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        .toolbar(hidesNavigationChrome ? .hidden : .automatic, for: .navigationBar)
        .refreshable {
            if let publication = appModel.selectedPublication {
                await appModel.loadEntries(for: publication)
            }
        }
    }
}

struct EntryRow: View {
    let entry: EntryListItem
    let isRead: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let raw = entry.thumbnailUrl, let url = URL(string: raw) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Color.secondary.opacity(0.12)
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if !isRead {
                        Circle()
                            .fill(.indigo)
                            .frame(width: 8, height: 8)
                    }
                    Text(entry.title)
                        .font(.headline)
                        .foregroundStyle(isRead ? .secondary : .primary)
                        .lineLimit(2)
                }
                if let summary = entry.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Text(Self.formatted(entry.publishedAt))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private static func formatted(_ raw: String) -> String {
        guard let date = DateFormatters.date(from: raw) else { return raw }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
