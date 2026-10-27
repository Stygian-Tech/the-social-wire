#if os(iOS)
import Feeds
import SwiftUI

struct TimelineFeedView: View {
    let timeline: TimelineModel
    let stories: StoryModel
    let pinnedFeeds: PinnedFeedsModel
    @State private var refreshExtrasTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // Stories load independently of timeline and external metadata.
                if stories.hasRailContent {
                    StoryRailView(model: stories)
                    Divider()
                }

                if timeline.posts.isEmpty, timeline.isLoading {
                    ProgressView("Loading Timeline")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                } else if timeline.posts.isEmpty, timeline.didFail {
                    ContentUnavailableView {
                        Label("Timeline Unavailable", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text("The Social Wire couldn’t load this feed. Check your connection and try again.")
                    } actions: {
                        Button("Try Again") {
                            Task { await timeline.retry() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    ForEach(timeline.threadGroups) { group in
                        VStack(alignment: .leading, spacing: 0) {
                            TimelineThreadGroupView(group: group)
                                .padding(.horizontal)

                            Divider()
                        }
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .videoPlaybackViewport()
        .refreshable {
            let previousRefresh = refreshExtrasTask
            previousRefresh?.cancel()
            refreshExtrasTask = Task {
                await previousRefresh?.value
                guard !Task.isCancelled else { return }
                async let storyRefresh: Void = stories.load()
                async let pinnedFeedRefresh: Void = pinnedFeeds.load()
                _ = await (storyRefresh, pinnedFeedRefresh)
            }
            await timeline.refreshVisibleContent()
        }
        .task { await timeline.load() }
        .task { await stories.load() }
        .onDisappear { refreshExtrasTask?.cancel() }
    }
}

#endif
