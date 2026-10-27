#if os(iOS)
import Feeds
import SwiftUI

struct FeedRouteView: View {
    @State private var timeline: TimelineModel
    let stockTicker: String?

    init(timeline: TimelineModel, stockTicker: String? = nil) {
        _timeline = State(initialValue: timeline)
        self.stockTicker = stockTicker
    }

    var body: some View {
        Group {
            if stockTicker == nil, timeline.posts.isEmpty, timeline.isLoading {
                loadingFeed
                    .frame(maxHeight: .infinity)
            } else if stockTicker == nil, timeline.posts.isEmpty, timeline.didFail {
                unavailableFeed
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            if timeline.posts.isEmpty, timeline.isLoading {
                                loadingFeed
                                    .padding()
                            } else if timeline.posts.isEmpty, timeline.didFail {
                                unavailableFeed
                            } else {
                                ForEach(timeline.threadGroups) { group in
                                    TimelineThreadGroupView(group: group)
                                        .environment(\.showsInlineStockCharts, stockTicker == nil)
                                        .padding(.horizontal)

                                    Divider()
                                        .padding(.leading, 68)
                                }

                                Color.clear
                                    .frame(height: 1)
                                    .task(id: "\(timeline.posts.last?.id ?? ""):\(timeline.paginationRevision)") {
                                        guard timeline.canLoadMore, let lastPost = timeline.posts.last else { return }
                                        await timeline.loadMore(after: lastPost)
                                    }

                                if timeline.isLoadingMore {
                                    ProgressView()
                                        .frame(maxWidth: .infinity)
                                        .padding()
                                        .accessibilityLabel("Loading More Posts")
                                } else if timeline.didFail {
                                    Button("Try Loading More") {
                                        Task { await timeline.retry() }
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                }
                            }
                        } header: {
                            if let stockTicker {
                                CashtagCardsView(text: "$\(stockTicker)", facets: [])
                                    .padding(.horizontal)
                                    .background(.background)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .refreshable {
                    await timeline.refreshVisibleContent()
                }
            }
        }
        .toolbarBackground(.background, for: .navigationBar)
        .toolbarBackground(stockTicker == nil ? .automatic : .visible, for: .navigationBar)
        .task {
            await timeline.load()
        }
    }

    private var loadingFeed: some View {
        ProgressView("Loading Feed")
            .frame(maxWidth: .infinity)
    }

    private var unavailableFeed: some View {
        ContentUnavailableView {
            Label("Feed Unavailable", systemImage: "wifi.exclamationmark")
        } description: {
            Text("The Social Wire couldn’t load this feed. Check your connection and try again.")
        } actions: {
            Button("Try Again") {
                Task { await timeline.retry() }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

#endif
