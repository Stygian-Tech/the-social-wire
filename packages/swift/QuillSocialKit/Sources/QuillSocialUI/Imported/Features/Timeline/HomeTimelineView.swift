#if os(iOS)
import Feeds
import SwiftUI

struct HomeTimelineView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(HomeFeedsModel.self) private var feeds
    @Environment(PinnedFeedsModel.self) private var pinnedFeeds
    @Environment(StoryModel.self) private var stories
    @State private var selectedFeedID = HomeFeedItem.home.id
    @State private var rejectsFeedTaps = false
    @State private var tapRejectionTask: Task<Void, Never>?
    @State private var showsComposer = false

    private var items: [HomeFeedItem] {
        [.home] + pinnedFeeds.feeds.map(HomeFeedItem.init(feed:))
    }

    private var selectedIndex: Int {
        items.firstIndex { $0.id == selectedFeedID } ?? 0
    }

    private var selectedItem: HomeFeedItem {
        items[selectedIndex]
    }

    var body: some View {
        TimelineFeedView(
            timeline: feeds.timeline(for: selectedItem),
            stories: stories,
            pinnedFeeds: pinnedFeeds
        )
        .id(selectedFeedID)
            .overlay(alignment: .bottomTrailing) {
                Button {
                    showsComposer = true
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 23, weight: .semibold))
                        .frame(width: 56, height: 56, alignment: .center)
                }
                .foregroundStyle(.white)
                .quillFloatingPostButtonStyle()
                .buttonBorderShape(.circle)
                .tint(.accentColor)
                .padding(20)
                .sensoryFeedback(.selection, trigger: showsComposer)
                .accessibilityLabel("New Post")
            }
            .overlay {
                // Intercept new taps without setting isEnabled, which dims every
                // control (and the chart) while a horizontal swipe is in flight.
                if rejectsFeedTaps {
                    Color.clear
                        .contentShape(.rect)
                        .onTapGesture {}
                        .accessibilityHidden(true)
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { value in
                        guard FeedSwipeGestureEvaluator.isHorizontalIntent(
                            translation: value.translation
                        ) else { return }

                        tapRejectionTask?.cancel()
                        rejectsFeedTaps = true
                    }
                    .onEnded { value in
                        if let destination = FeedSwipeGestureEvaluator.destinationIndex(
                            currentIndex: selectedIndex,
                            feedCount: items.count,
                            translation: value.translation,
                            predictedEndTranslation: value.predictedEndTranslation
                        ) {
                            select(items[destination])
                        }

                        releaseFeedTapsAfterGesture()
                    }
            )
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HomeFeedPicker(items: items, selection: $selectedFeedID)
                }
            }
            .sensoryFeedback(.selection, trigger: selectedFeedID)
            .onChange(of: items) { _, updatedItems in
                if !updatedItems.contains(where: { $0.id == selectedFeedID }) {
                    selectedFeedID = HomeFeedItem.home.id
                }
            }
            .task(id: selectedFeedID) {
                await prefetchAdjacentFeeds()
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                async let storyLoad: Void = stories.load()
                async let pinnedFeedLoad: Void = pinnedFeeds.load()
                _ = await (storyLoad, pinnedFeedLoad)
            }
            .onDisappear {
                tapRejectionTask?.cancel()
                rejectsFeedTaps = false
            }
            .sheet(isPresented: $showsComposer, onDismiss: {
                Task { await feeds.timeline(for: selectedItem).refresh() }
            }) {
                PostComposerView()
            }
    }

    private func releaseFeedTapsAfterGesture() {
        tapRejectionTask?.cancel()
        tapRejectionTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            rejectsFeedTaps = false
        }
    }

    private func select(_ item: HomeFeedItem) {
        selectedFeedID = item.id
    }

    private func prefetchAdjacentFeeds() async {
        let currentItems = items
        let currentIndex = currentItems.firstIndex { $0.id == selectedFeedID } ?? 0
        let neighbors = [currentIndex - 1, currentIndex + 1]
            .filter { currentItems.indices.contains($0) }
            .map { currentItems[$0] }
        let timelines = neighbors.map { feeds.timeline(for: $0) }

        await withTaskGroup(of: Void.self) { group in
            for timeline in timelines {
                group.addTask { await timeline.load() }
            }
        }
    }
}

#endif
