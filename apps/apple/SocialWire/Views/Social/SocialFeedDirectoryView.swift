import SwiftUI

struct SocialFeedDirectoryView: View {
    @Bindable var model: SocialCatalogModel
    let navigate: (SocialRoute) -> Void
    var body: some View {
        List(model.feeds) { feed in
            Button { navigate(.feed(uri: feed.uri, name: feed.displayName)) } label: {
                HStack(spacing: 12) { SocialAvatarView(url: feed.avatar, name: feed.displayName); VStack(alignment: .leading, spacing: 3) { Text(feed.displayName).font(.headline); Text(feed.description).font(.caption).foregroundStyle(.secondary).lineLimit(2); Text("by \(feed.creator.preferredName)").font(.caption2).foregroundStyle(.secondary) } }
            }.buttonStyle(.plain)
        }
        .searchable(text: $model.feedQuery, prompt: "Search Feeds")
        .task(id: model.feedQuery) { do { try await Task.sleep(for: .milliseconds(300)); await model.loadFeeds() } catch { } }
        .overlay { if model.isLoading && model.feeds.isEmpty { ProgressView() } else if let error = model.error, model.feeds.isEmpty { ContentUnavailableView("Feeds Unavailable", systemImage: "rectangle.stack", description: Text(error)) } }
    }
}
