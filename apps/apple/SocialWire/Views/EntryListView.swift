import SwiftUI

struct EntryListView: View {
    @Environment(SocialWireAppModel.self) private var appModel

    var body: some View {
        List {
            if appModel.isLoadingEntries {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else if appModel.filteredEntries.isEmpty {
                ContentUnavailableView("No Articles", systemImage: "doc.text")
            } else {
                Section("Articles") {
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
        }
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
            Group {
                if !isRead {
                    Circle()
                        .fill(Color.primary)
                        .frame(width: 8, height: 8)
                } else {
                    Color.clear
                        .frame(width: 8, height: 8)
                }
            }
            .frame(width: 8)

            thumbnail

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title)
                    .font(.headline)
                    .foregroundStyle(isRead ? .secondary : .primary)
                    .lineLimit(2)

                if let summary = entry.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(Self.formatted(entry.publishedAt))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var thumbnail: some View {
        Group {
            if let raw = entry.thumbnailUrl, let url = URL(string: raw) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        thumbnailPlaceholder
                    }
                }
            } else {
                thumbnailPlaceholder
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var thumbnailPlaceholder: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(.tertiarySystemFill))
    }

    private static func formatted(_ raw: String) -> String {
        guard let date = DateFormatters.date(from: raw) else { return raw }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
