import SwiftUI

struct CircleNewsView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let sceneModel: NewsSceneModel
    @State private var lastHiddenStory: CircleStory?
    @State private var isRefreshing = false

    private var contentState: CircleContentState {
        CircleContentState(
            catalog: appModel.circleCatalog,
            storyCount: appModel.circleEdition?.stories.count,
            visibleStoryCount: appModel.visibleCircleStories.count,
            isLoading: appModel.isLoadingCircle,
            errorMessage: appModel.circleErrorMessage,
            limitedCoverage: appModel.circleEdition?.degraded == true
                || appModel.circleEdition?.source == .staleGeneration
        )
    }

    var body: some View {
        editorialCanvas
        .task(id: appModel.circleCatalog?.isAvailable) {
            if appModel.circleEdition == nil, !isRefreshing {
                await appModel.loadCircleEdition()
            }
        }
        .overlay(alignment: .bottom) {
            if let lastHiddenStory {
                HStack(spacing: 12) {
                    Text("Story hidden")
                    Button("Undo") {
                        self.lastHiddenStory = nil
                        Task { await appModel.setCircleStory(lastHiddenStory, hidden: false) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: .capsule)
                .padding()
            }
        }
    }

    private var editorialCanvas: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                if let message = appModel.circleErrorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                switch contentState {
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 260)
                case .notReady:
                    ContentUnavailableView(
                        "Your Circle Is Not Ready Yet",
                        systemImage: "person.2.wave.2",
                        description: Text("Stories for Your Circle aren’t available right now. Please check back later.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 260)
                case .refreshing:
                    ContentUnavailableView(
                        "Your Circle Is Refreshing",
                        systemImage: "person.2.wave.2",
                        description: Text("Network coverage is limited right now. Please check back as Your Circle refreshes.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 260)
                case .buildingNetwork:
                    ContentUnavailableView(
                        "Your Circle Is Still Taking Shape",
                        systemImage: "person.2.wave.2",
                        description: Text("Your Circle needs recent shared links from people you follow and their connections. Stories will appear here when there’s enough activity to build your feed.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 260)
                case .failed:
                    ContentUnavailableView(
                        "Your Circle Couldn’t Load",
                        systemImage: "exclamationmark.triangle",
                        description: Text("Refresh to try again.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 260)
                case .noVisibleStories:
                    ContentUnavailableView(
                        "Nothing from Your Circle Yet",
                        systemImage: "person.2.wave.2",
                        description: Text("New stories will appear as people in your network share them.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 260)
                case .stories:
                    EditorialCardLayout(
                        spacing: 18,
                        minimumCardWidth: dynamicTypeSize.isAccessibilitySize ? 900 : 240
                    ) {
                        ForEach(appModel.visibleCircleStories, id: \.storyId) { story in
                            CircleStoryCard(
                                story: story,
                                onReadInApp: { openStory(story) },
                                onHide: { hide(story) }
                            )
                            .onAppear {
                                guard story.storyId == appModel.visibleCircleStories.last?.storyId,
                                      let cursor = appModel.circleEdition?.moreCursor
                                else { return }
                                Task { await appModel.loadCircleEdition(cursor: cursor) }
                            }
                        }
                    }
                    if appModel.isLoadingCircle {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }
                if contentState != .loading, contentState != .stories {
                    Button("Retry") {
                        Task { await refreshCircle() }
                    }
                    .disabled(isRefreshing || appModel.isLoadingCircle)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding()
            .frame(maxWidth: ArticleReadingWidth.editorial, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await refreshCircle() }
    }

    private func refreshCircle() async {
        guard !isRefreshing, !appModel.isLoadingCircle else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await appModel.refreshCircleCatalog()
        await appModel.loadCircleEdition()
    }

    private func openStory(_ story: CircleStory) {
        let target = EntryOpenTargetResolver.resolve(
            entryId: story.storyId,
            originalURL: story.canonicalUrl,
            rssArticleOpenMode: appModel.feedPreferences.articleOpenMode
        )
        switch target {
        case .external(let websiteURL):
            openURL(websiteURL)
        case .nativeRSS:
            appModel.selectCircleStory(story)
            guard appModel.selectedEntry?.entryId == story.storyId else { return }
            sceneModel.navigate(to: .entry(id: story.storyId), in: .circle)
        case nil:
            appModel.errorMessage = "Couldn't Find A Link For This Article."
        }
    }

    private func hide(_ story: CircleStory) {
        lastHiddenStory = story
        Task { await appModel.setCircleStory(story, hidden: true) }
    }
}

/// On macOS this matches the shared article card treatment, with Your Circle's sharer
/// strip and hide action composed around it. iOS keeps the original metrics for the
/// same reason The Wire does — a 16:9 banner is too tall for the phone canvas.
struct CircleStoryCard: View {
    let story: CircleStory
    let onReadInApp: () -> Void
    let onHide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            storyImage

            VStack(alignment: .leading, spacing: contentSpacing) {
                CircleSharerStrip(
                    sharers: story.sharers,
                    totalCount: story.sharerCount ?? story.sharers.count
                )

                Text(story.source.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let url = URL(string: story.canonicalUrl) {
                    Link(destination: url) {
                        title
                    }
                    .accessibilityHint("Opens the publisher's website")
                } else {
                    title
                }

                if let summary = story.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                NewsStoryActions(
                    onOpenStory: onReadInApp,
                    onHide: onHide
                )

                #if os(macOS)
                // Cards in a band share one height; pin the content to the top of it.
                Spacer(minLength: 0)
                #endif
            }
            .padding(contentPadding)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: .rect(cornerRadius: 16))
        .clipShape(.rect(cornerRadius: 16))
        .multilineTextAlignment(.leading)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var storyImage: some View {
        #if os(macOS)
        ArticleCardImage(
            urls: ThumbnailImageURLAttempts.candidates(
                primary: story.thumbnailUrl,
                fallback: nil
            )
        )
        #else
        if let thumbnailUrl = story.thumbnailUrl {
            NewsStoryImage(
                urls: [URL(string: thumbnailUrl)].compactMap { $0 },
                height: 200
            )
        }
        #endif
    }

    private var title: some View {
        #if os(macOS)
        Text(story.title)
            .font(.headline)
            .foregroundStyle(Color.primary)
            .lineLimit(3)
            .multilineTextAlignment(.leading)
        #else
        Text(story.title)
            .font(.title3.bold())
            .foregroundStyle(Color.primary)
            .multilineTextAlignment(.leading)
        #endif
    }

    private var contentSpacing: CGFloat {
        #if os(macOS)
        ArticleCardMetrics.spacing
        #else
        12
        #endif
    }

    private var contentPadding: CGFloat {
        #if os(macOS)
        ArticleCardMetrics.padding
        #else
        16
        #endif
    }
}

private struct CircleSharerStrip: View {
    let sharers: [CircleSharer]
    let totalCount: Int

    var body: some View {
        if !sharers.isEmpty {
            HStack(spacing: 8) {
                HStack(spacing: -8) {
                    ForEach(Array(visibleSharers.enumerated()), id: \.element.sourceUri) { index, sharer in
                        ZStack(alignment: .bottomTrailing) {
                            Group {
                                if let raw = sharer.identity.avatarUrl, let url = URL(string: raw) {
                                    CachedRemoteImage(urls: [url], maxPixelSize: 80) {
                                        Circle().fill(.quaternary)
                                    }
                                    .scaledToFill()
                                } else {
                                    Circle().fill(.quaternary)
                                }
                            }
                            .frame(width: 30, height: 30)
                            .clipShape(.circle)
                            .overlay { Circle().stroke(.background, lineWidth: 2) }

                            if sharer.relationship == "one_hop" {
                                Text("+1")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(Color.primary)
                                    .padding(.horizontal, 2)
                                    .background(.background, in: Capsule())
                                    .overlay { Capsule().stroke(.quaternary, lineWidth: 1) }
                                    .offset(x: 2, y: 2)
                                    .accessibilityHidden(true)
                            }
                        }
                        .zIndex(Double(visibleSharers.count - index))
                    }
                }
                if overflowCount > 0 {
                    Text("+\(overflowCount)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)
        }
    }

    private var visibleSharers: [CircleSharer] {
        var sourceURIs = Set<String>()
        return Array(sharers.lazy.filter { sourceURIs.insert($0.sourceUri).inserted }.prefix(5))
    }

    private var accessibilitySummary: String {
        let accounts = visibleSharers.map { sharer in
            let displayName = sharer.identity.displayName
            let name = displayName?.isEmpty == false ? displayName ?? sharer.identity.handle : sharer.identity.handle
            return sharer.relationship == "one_hop" ? "\(name), one hop away" : name
        }
        let remainder = overflowCount > 0 ? ", and \(overflowCount) more accounts" : ""
        return "Shared by \(accounts.joined(separator: ", "))\(remainder)"
    }

    private var overflowCount: Int {
        max(0, totalCount - visibleSharers.count)
    }
}
