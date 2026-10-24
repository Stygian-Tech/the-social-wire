import SwiftUI

struct SocialProfileView: View {
    let did: String
    let client: SocialWireSocialClient
    let navigate: (SocialRoute) -> Void
    @State private var profile: SocialProfile?
    @State private var posts: [SocialPost] = []
    @State private var error: String?
    @State private var isFollowing = false
    @State private var followURI: String?

    var body: some View {
        List {
            if let profile {
                SocialProfileHeader(profile: profile, isFollowing: isFollowing) { Task { await toggleFollow() } }
                Section("Posts") {
                    ForEach(posts) { post in
                        Button { navigate(.post(uri: post.uri)) } label: {
                            VStack(alignment: .leading, spacing: 5) { Text(post.text); Text(post.createdAt, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary) }
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .overlay { if profile == nil && error == nil { ProgressView() } else if let error { ContentUnavailableView("Profile Unavailable", systemImage: "person.crop.circle.badge.exclamationmark", description: Text(error)) } }
        .navigationTitle(profile?.author.preferredName ?? "Profile")
        .task(id: did) { await load() }
    }

    private func load() async {
        do {
            async let loadedProfile = client.profile(actor: did)
            async let loadedPosts = client.authorFeed(actor: did)
            let result = try await (loadedProfile, loadedPosts)
            profile = result.0; posts = result.1.items; followURI = result.0.viewerFollowingURI; isFollowing = followURI != nil
        } catch { self.error = error.localizedDescription }
    }

    private func toggleFollow() async {
        do {
            if let followURI { try await client.deleteRecord(uri: followURI, collection: "app.bsky.graph.follow"); self.followURI = nil; isFollowing = false }
            else { followURI = try await client.follow(did: did); isFollowing = true }
        } catch { self.error = error.localizedDescription }
    }
}

private struct SocialProfileHeader: View {
    let profile: SocialProfile
    let isFollowing: Bool
    let toggleFollow: () -> Void
    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                if let banner = profile.banner { AsyncImage(url: banner) { $0.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.12) }.frame(height: 130).clipped() }
                HStack { SocialAvatarView(url: profile.author.avatar, name: profile.author.preferredName, size: 72); Spacer(); Button(isFollowing ? "Following" : "Follow", action: toggleFollow).buttonStyle(.borderedProminent) }
                Text(profile.author.preferredName).font(.title2.bold())
                Text("@\(profile.author.handle)").foregroundStyle(.secondary)
                if !profile.description.isEmpty { Text(profile.description) }
                HStack(spacing: 16) { Text("\(profile.followsCount) Following"); Text("\(profile.followersCount) Followers"); Text("\(profile.postsCount) Posts") }.font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
