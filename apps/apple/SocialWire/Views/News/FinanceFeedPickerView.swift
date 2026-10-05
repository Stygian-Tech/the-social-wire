import SwiftUI

struct FinanceFeedPickerView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var matchingFeeds: [FinanceNamedFeed] {
        appModel.financeFeeds.filter { $0.isVisible(hideCrypto: appModel.feedPreferences.hideFinanceCrypto) && $0.matchesSearch(query) }
    }

    private var groups: [String] {
        ["Finance", "Stocks", "ETFs", "Crypto", "Indices", "Commodities", "Industries"].filter { group in
            matchingFeeds.contains { $0.pickerGroup == group }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(groups, id: \.self) { group in
                    Section(group) {
                        ForEach(matchingFeeds.filter { $0.pickerGroup == group }) { feed in
                            Button {
                                Task { await appModel.selectFinanceFeed(feed.id) }
                                dismiss()
                            } label: {
                                HStack {
                                    Image(systemName: feed.systemImage).accessibilityHidden(true)
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
                    }
                }
            }
            .searchable(text: $query, prompt: "Search Securities, Industries, or Groups")
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
