#if DEBUG
import SwiftUI

/// Deterministic shell used only by UI automation so navigation chrome can be tested without live OAuth.
struct NewsShellUITestHarness: View {
    @State private var fixtureModel = SocialWireAppModel()
    @State private var isShellConfigured = false
    @State private var lastFeedAction = "Ready"
    @State private var readAgeRevision = 0

    var body: some View {
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-read-age") {
            readAgeFixture
        } else if ProcessInfo.processInfo.arguments.contains("--ui-testing-feed-cards") {
            feedCardFixture
        } else {
            shell
        }
    }

    private var readAgeFixture: some View {
        VStack(spacing: 24) {
            Text(lastFeedAction).accessibilityIdentifier("feed-action-result")
            FeedMarkReadButton(
                contextID: "read-age-fixture",
                refreshRevision: readAgeRevision,
                scopeTitle: "Test Feed",
                loadOptions: {
                    [
                        FeedReadAgeOption(days: 1, before: "2026-09-02T05:00:00Z", count: 6),
                        FeedReadAgeOption(days: 2, before: "2026-09-01T05:00:00Z", count: 4),
                        FeedReadAgeOption(days: 4, before: "2026-08-30T05:00:00Z", count: 1),
                    ].filter { readAgeRevision == 0 || $0.days != 2 }
                },
                markAllRead: { lastFeedAction = "All Read" },
                markOlderRead: { lastFeedAction = "Read Before \($0.before)" },
                markAllUnread: { lastFeedAction = "All Unread" }
            )
            Button("Read Yesterday's Stories") { readAgeRevision += 1 }
                .accessibilityIdentifier("fixture-read-stories")
        }
    }

    private var shell: some View {
        Group {
            if isShellConfigured {
                NewsShellView()
                    .environment(fixtureModel)
                    .safeAreaInset(edge: .bottom) {
                        if ProcessInfo.processInfo.arguments.contains("--ui-testing-shell-routing") {
                            HStack {
                                Button("Hide Following") {
                                    fixtureModel.feedPreferences.visibleFeeds = [.readLater, .archive, .subscribed]
                                }
                                .accessibilityIdentifier("fixture-hide-following")
                                Button("Select Publication") {
                                    // Same completed selection observed after Profile/sidebar selection;
                                    // no live OAuth, repository, or feed network dependency.
                                    let publication = Self.fixturePublication
                                    fixtureModel.selectedPublication = publication
                                    fixtureModel.feedSelection = .publication(publication.publicationId)
                                    fixtureModel.selectedSidebar = .publication(publication.publicationId)
                                    fixtureModel.entries = [Self.entry(index: 1)]
                                }
                                .accessibilityIdentifier("fixture-select-publication")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
            } else {
                ProgressView()
                    .task {
                        fixtureModel.feedPreferences = ReaderFeedPreferences(
                            visibleFeeds: [.readLater, .archive, .subscribed, .following],
                            feedsWithUnreadCounts: [], showWire: false, showCircle: false)
                        // Start from the default Subscribed selection; avoid live fetch work.
                        fixtureModel.readerListSource = .subscribed
                        fixtureModel.feedSelection = .topLevel(.subscribed)
                        isShellConfigured = true
                    }
            }
        }
    }

    private static let fixturePublication = DiscoveredPublication(
        publicationId: "at://did:plc:fixture/site.standard.publication/main",
        authorDid: "did:plc:fixture", authorHandle: "fixture.example",
        title: "Fixture Publication", discoveredAt: "2026-09-01T00:00:00Z")

    private var feedCardFixture: some View {
        VStack(spacing: 12) {
            Text(lastFeedAction)
                .font(.caption)
                .dynamicTypeSize(.medium)
                .accessibilityIdentifier("feed-action-result")

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if ProcessInfo.processInfo.arguments.contains("--ui-testing-circle") {
                        CircleStoryCard(
                            story: Self.circleStory,
                            onReadInApp: { lastFeedAction = "Open" },
                            onHide: { lastFeedAction = "Hidden" }
                        )
                    } else {
                        WireEditorialRail(
                            title: "Trending",
                            entries: [Self.entry(index: 1), Self.entry(index: 2)],
                            onOpen: { _ in lastFeedAction = "Open" }
                        )
                    }
                }
                .frame(width: 320, alignment: .leading)
                .padding(.vertical, 12)
            }
            .frame(width: 320)
            .accessibilityIdentifier("feed-canvas")
            .dynamicTypeSize(
                ProcessInfo.processInfo.arguments.contains("--ui-testing-large-text")
                    ? .accessibility3 : .large
            )
            .environment(\.openURL, OpenURLAction { _ in
                lastFeedAction = "Website"
                return .handled
            })
        }
    }

    private static let fixtureTitle = "A Long Headline About Communities Building a More Open and Connected Social Web"
    private static let fixtureSource = WireFeedSource(
        name: "The International Journal of Independent Community Publishing",
        domain: "community-publications.example"
    )

    private static func entry(index: Int) -> EntryListItem {
        EntryListItem(
            entryId: "ui-story-\(index)",
            title: index == 1 ? "A Short Headline" : fixtureTitle,
            summary: "People are sharing thoughtful stories and practical ideas across their communities every day.",
            publishedAt: "2026-09-02T12:00:00Z",
            formattedPublishedAt: "Today",
            thumbnailUrl: nil,
            thumbnailFallbackUrl: nil,
            originalUrl: "https://community-publications.example/story-\(index)",
            wireMetadata: WireEntryMetadata(
                source: fixtureSource,
                reasons: [],
                provenance: [],
                representativeUri: nil
            )
        )
    }

    private static var circleStory: CircleStory {
        CircleStory(
            storyId: "ui-circle-story",
            canonicalUrl: "https://community-publications.example/circle-story",
            representativeUri: nil,
            title: fixtureTitle,
            summary: "People are sharing thoughtful stories and practical ideas across their communities every day.",
            publishedAt: "2026-09-02T12:00:00Z",
            thumbnailUrl: nil,
            source: fixtureSource,
            reasons: [],
            discussionCount: 8,
            sharerCount: 7,
            sharers: (1...5).map { index in
                CircleSharer(
                    identity: CirclePublicIdentity(
                        did: "did:plc:fixture\(index)",
                        handle: "community-writer-\(index).example",
                        displayName: "Community Writer \(index)",
                        avatarUrl: nil
                    ),
                    relationship: index == 5 ? "one_hop" : "following",
                    action: "share",
                    sourceUri: "at://did:plc:fixture\(index)/app.bsky.feed.post/story",
                    timestamp: "2026-09-02T12:00:00Z"
                )
            }
        )
    }
}
#endif
