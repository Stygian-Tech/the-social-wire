#if os(iOS)
import Feeds
import SwiftUI

struct StoryRailView: View {
    let model: StoryModel
    @Environment(AppServices.self) private var services

    @State private var isCreatingStory = false
    @State private var selectedItem: StoryFeedItem?
    @State private var seenStore = StorySeenStore()
    @State private var selectionFeedback = 0
    @ScaledMetric(relativeTo: .body) private var railHeight = 106.0

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 14) {
                ForEach(model.items) { item in
                    Button {
                        guard !item.stories.isEmpty else {
                            if item.isCurrentUser && model.canPublish { isCreatingStory = true }
                            return
                        }
                        selectedItem = item
                        selectionFeedback += 1
                    } label: {
                        StoryAvatarView(
                            item: item,
                            showsAccentRing: showsAccentRing(for: item),
                            showsAddBadge: item.stories.isEmpty
                        )
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .topTrailing) {
                        if item.isCurrentUser && model.canPublish && !item.stories.isEmpty {
                            Button("Add to Your Story", systemImage: "plus.circle.fill") {
                                isCreatingStory = true
                                selectionFeedback += 1
                            }
                            .labelStyle(.iconOnly)
                            .font(.title2)
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
        .frame(height: railHeight)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .sensoryFeedback(.selection, trigger: selectionFeedback)
        .fullScreenCover(item: $selectedItem) { item in
            StoryViewerView(items: model.items, startingAuthorID: item.id, stories: model) { story in
                seenStore.markSeen(story)
            }
        }
        .sheet(isPresented: $isCreatingStory) { StoryComposerView(stories: model) }
        .task {
            let viewerDID = try? await services.currentAccountDID()
            guard !Task.isCancelled else { return }
            seenStore.bind(viewerDID: viewerDID)
            await model.load()
        }
    }

    private func showsAccentRing(for item: StoryFeedItem) -> Bool {
        if item.isCurrentUser {
            return !item.stories.isEmpty
        }
        return item.stories.contains { !seenStore.hasSeen($0) }
    }
}

#endif
