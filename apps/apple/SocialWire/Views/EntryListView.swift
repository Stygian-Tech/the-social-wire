import SwiftUI

/// Column 2: Scrollable list of entries for the selected publication.
struct EntryListView: View {
    let publication: PublicationModel
    @ObservedObject var viewModel: MainViewModel

    var body: some View {
        List(selection: Binding(
            get: { viewModel.selectedEntry?.entryId },
            set: { id in
                if let id, let entry = viewModel.entries.first(where: { $0.entryId == id }) {
                    viewModel.selectEntry(entry)
                }
            }
        )) {
            ForEach(viewModel.entries) { entry in
                EntryRowView(entry: entry)
                    .tag(entry.entryId)
            }
        }
        .listStyle(.plain)
        .overlay {
            if viewModel.entries.isEmpty {
                ContentUnavailableView(
                    "No Entries",
                    systemImage: "doc.text",
                    description: Text("This publication has no entries yet.")
                )
            }
        }
    }
}

struct EntryRowView: View {
    let entry: EntryModel

    private var formattedDate: String {
        let date = entry.publishedAt
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)

            if let summary = entry.summary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Text(formattedDate)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}
