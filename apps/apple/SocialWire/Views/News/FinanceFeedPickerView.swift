import SwiftUI

struct FinanceFeedPickerView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var matchingFeeds: [FinanceNamedFeed] {
        appModel.financeFeeds.filter { $0.matchesSearch(query) }
    }

    var body: some View {
        NavigationStack {
            List(matchingFeeds) { feed in
                Button {
                    Task { await appModel.selectFinanceFeed(feed.id) }
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(feed.title).foregroundStyle(.primary)
                            Text(feed.description).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if appModel.selectedFinanceFeedID == feed.id {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
                .accessibilityAddTraits(appModel.selectedFinanceFeedID == feed.id ? .isSelected : [])
            }
            .searchable(text: $query, prompt: "Search Companies, Industries, or Groups")
            .overlay {
                if matchingFeeds.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .navigationTitle("Finance Feeds")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
