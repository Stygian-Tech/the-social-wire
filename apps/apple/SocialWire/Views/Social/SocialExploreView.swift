import SwiftUI

struct SocialExploreView: View {
    @Bindable var model: SocialDiscoveryModel
    let navigate: (SocialRoute) -> Void

    var body: some View {
        List {
            if !model.actors.isEmpty {
                Section("People") {
                    ForEach(model.actors) { actor in
                        Button { navigate(.profile(did: actor.did)) } label: {
                            HStack { SocialAvatarView(url: actor.avatar, name: actor.preferredName); VStack(alignment: .leading) { Text(actor.preferredName); Text("@\(actor.handle)").font(.caption).foregroundStyle(.secondary) } }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !model.posts.isEmpty {
                Section("Posts") {
                    ForEach(model.posts) { post in
                        Button { navigate(.post(uri: post.uri)) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(post.author.preferredName).font(.headline)
                                Text(post.text).lineLimit(4)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .searchable(text: $model.query, prompt: "People, Posts, and Topics")
        .task(id: model.query) {
            do { try await Task.sleep(for: .milliseconds(300)); await model.search() } catch { }
        }
        .overlay {
            if model.isLoading { ProgressView() }
            else if model.query.isEmpty { ContentUnavailableView("Explore Social", systemImage: "magnifyingglass", description: Text("Search for people, posts, hashtags, or cashtags.")) }
            else if let error = model.error, model.actors.isEmpty && model.posts.isEmpty { ContentUnavailableView("Search Unavailable", systemImage: "exclamationmark.triangle", description: Text(error)) }
        }
    }
}
