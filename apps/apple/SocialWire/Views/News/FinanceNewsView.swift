import SwiftUI

struct FinanceNewsView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.openURL) private var openURL
    @State private var scrollAnchor: String?
    @State private var showingFeedPicker = false
    @State private var showingCustomization = false
    let sceneModel: NewsSceneModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(appModel.selectedFinanceFeed.title).font(.largeTitle.bold())
                    Spacer()
                    Button("Customize", systemImage: "slider.horizontal.3") { showingCustomization = true }
                }
                Button("Choose Feed", systemImage: "line.3.horizontal.decrease") { showingFeedPicker = true }
                    .accessibilityValue(appModel.selectedFinanceFeed.title)
                if appModel.selectedFinanceFeedID != "finance" {
                    Text("Only Stories Matching This Feed").font(.caption).foregroundStyle(.secondary)
                }
                if let instrument = appModel.selectedFinanceFeed.resolvedInstrument(
                    metadata: appModel.financeInstrumentMetadata, items: appModel.financeItems
                ) {
                    FinanceInstrumentOverview(instrument: instrument,
                        hidePerformance: appModel.feedPreferences.hideFinancePerformance,
                        widgetsEnabled: appModel.financePage?.widgetsEnabled == true,
                        items: appModel.financeItems)
                    Text("Latest News").font(.title2.bold())
                }
                if let error = appModel.financeError {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                    Button("Retry") { Task { await appModel.loadFinance() } }
                }
                if appModel.isLoadingFinance, appModel.financeItems.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 180)
                } else if appModel.financeItems.isEmpty {
                    ContentUnavailableView("No Matching Stories Yet", systemImage: "chart.line.uptrend.xyaxis",
                        description: Text(appModel.selectedFinanceFeedID == "finance"
                            ? "Finance Stories Will Appear Here When Available."
                            : "No Validated Stories Currently Match This Feed."))
                }
                ForEach(appModel.financeItems) { item in
                    WireStoryCard(entry: item.story.toEntryListItem()) { open(item) }
                        .id(item.id)
                }
                if appModel.financeContinuationSuspended {
                    Button("Refresh Personalized Feed") { Task { await appModel.loadFinance() } }
                } else if let cursor = appModel.financePage?.cursor {
                    Button("More Stories") { Task { await appModel.loadFinance(cursor: cursor) } }
                        .disabled(appModel.isLoadingFinance)
                }
            }
            .scrollTargetLayout()
            .padding()
            .frame(maxWidth: ArticleReadingWidth.editorial)
            .frame(maxWidth: .infinity)
        }
        .scrollPosition(id: $scrollAnchor)
        .refreshable { await appModel.loadFinance() }
        .task(id: appModel.viewerDID) {
            await appModel.loadFinanceFeeds()
            await appModel.loadFinance()
        }
        .onChange(of: appModel.selectedFinanceFeedID) { _, _ in scrollAnchor = nil }
        .sheet(isPresented: $showingFeedPicker) { FinanceFeedPickerView() }
        .sheet(isPresented: $showingCustomization) { FinanceCustomizationView() }
    }

    private func open(_ item: FinanceFeedItem) {
        guard let url = URL(string: item.story.canonicalUrl) else { return }
        openURL(url)
    }
}
