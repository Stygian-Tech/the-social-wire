#if os(iOS)
import ATProtoCore
import Feeds
import SwiftUI

struct ExploreView: View {
    @Environment(AppServices.self) private var services
    @Environment(PinnedFeedsModel.self) private var pinnedFeeds
    @Environment(\.routeNavigator) private var navigator
    @State private var model = ExploreModel()
    @State private var query = ""
    @State private var showsFeedManagement = false

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        List {
            if isSearching {
                searchResults
            } else {
                discoveryContent
            }
        }
        .listStyle(.insetGrouped)
        .roundedNavigationTitle("Explore", inlineTitleFont: .body.weight(.semibold))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Manage Feeds", systemImage: "rectangle.stack.badge.plus") {
                    showsFeedManagement = true
                }
            }
        }
        .sheet(isPresented: $showsFeedManagement) {
            FeedManagementSheet(model: pinnedFeeds) { feed in
                showsFeedManagement = false
                navigator?(.feed(feed.uri))
            }
        }
        .searchable(text: $query, prompt: "Search People and Feeds")
        .onChange(of: query) { _, value in
            model.search(value, using: services.appViewRequest)
        }
        .task {
            await model.load(using: services.appViewRequest)
        }
        .refreshable {
            await model.load(using: services.appViewRequest)
        }
    }

    @ViewBuilder
    private var discoveryContent: some View {
        if model.isLoading, model.trends.isEmpty, model.suggestedFeeds.isEmpty {
            Section {
                HStack {
                    Spacer()
                    ProgressView("Loading Explore")
                    Spacer()
                }
            }
        }

        if let errorMessage = model.errorMessage,
           model.trends.isEmpty,
           model.suggestedFeeds.isEmpty {
            Section {
                ContentUnavailableView(
                    "Explore Unavailable",
                    systemImage: "wifi.exclamationmark",
                    description: Text(errorMessage)
                )
            }
        }

        if !model.trends.isEmpty {
            Section("Trending") {
                ForEach(model.trends) { trend in
                    Button {
                        navigator?(.hashtag(trend.displayName))
                    } label: {
                        trendRow(trend)
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        if !model.suggestedFeeds.isEmpty {
            Section("Discover Feeds") {
                ForEach(model.suggestedFeeds) { feed in
                    Button {
                        openFeed(feed)
                    } label: {
                        feedRow(feed)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        if model.isSearching {
            Section {
                HStack {
                    Spacer()
                    ProgressView("Searching")
                    Spacer()
                }
            }
        }

        if !model.actors.isEmpty {
            Section("People") {
                ForEach(model.actors) { actor in
                    Button {
                        openActor(actor)
                    } label: {
                        actorRow(actor)
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        if !model.matchingFeeds.isEmpty {
            Section("Feeds") {
                ForEach(model.matchingFeeds) { feed in
                    Button {
                        openFeed(feed)
                    } label: {
                        feedRow(feed)
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        if !model.isSearching, model.actors.isEmpty, model.matchingFeeds.isEmpty {
            Section {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    private func trendRow(_ trend: ExploreModel.Trend) -> some View {
        HStack(spacing: 12) {
            Image(systemName: trend.category == nil ? "chart.line.uptrend.xyaxis" : "flame.fill")
                .foregroundStyle(.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(trend.displayName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                if let description = trend.description, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            Text(trend.postCount, format: .number.notation(.compactName))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .contentShape(.rect)
    }

    private func actorRow(_ actor: ExploreModel.Actor) -> some View {
        HStack(spacing: 12) {
            avatar(url: actor.avatar, fallback: "person.crop.circle.fill")

            VStack(alignment: .leading, spacing: 2) {
                Text(actor.displayName ?? actor.handle)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("@\(actor.handle)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(.rect)
    }

    private func feedRow(_ feed: ExploreModel.Feed) -> some View {
        HStack(alignment: .top, spacing: 12) {
            avatar(url: feed.avatar, fallback: "rectangle.stack.fill")

            VStack(alignment: .leading, spacing: 3) {
                Text(feed.displayName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("by \(feed.creator.displayName ?? feed.creator.handle)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let description = feed.description, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            if pinnedFeeds.isSubscribed(to: feed.uri) {
                Label("Subscribed", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Subscribed")
            } else if let likeCount = feed.likeCount {
                Label(likeCount.formatted(.number.notation(.compactName)), systemImage: "heart")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(.rect)
    }

    private func avatar(url: URL?, fallback: String) -> some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: fallback)
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
                .padding(6)
        }
        .frame(width: 44, height: 44)
        .background(.fill.tertiary)
        .clipShape(.rect(cornerRadius: 10))
    }

    private func openActor(_ actor: ExploreModel.Actor) {
        guard let identifier = try? ActorIdentifier(actor.did) else { return }
        navigator?(.profile(identifier))
    }

    private func openFeed(_ feed: ExploreModel.Feed) {
        guard let uri = try? ATURI(feed.uri) else { return }
        navigator?(.feed(uri))
    }
}

#endif
