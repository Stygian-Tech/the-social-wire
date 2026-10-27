#if os(iOS)
import Feeds
import SwiftUI

struct ProfileHeaderView: View {
    let profile: ProfileModel.Profile
    let links: [URL]
    let germAvailability: ProfileModel.GermAvailability?
    let storyItem: StoryFeedItem?
    let stories: StoryModel
    let topSafeAreaInset: CGFloat
    let isCurrentProfile: Bool
    let isFollowing: Bool
    let isUpdatingFollow: Bool
    let followErrorGeneration: Int
    let onFollow: () -> Void

    @State private var presentedStory: StoryFeedItem?
    @State private var seenStore = StorySeenStore()

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                banner
                    .frame(height: 112 + topSafeAreaInset)
                    .clipped()
                    .ignoresSafeArea(edges: [.top, .trailing])

                avatarButton
                    .offset(y: 40)
                    .zIndex(1)
            }
            .zIndex(1)
            .padding(.top, -topSafeAreaInset)

            VStack(spacing: 8) {
                VStack(spacing: 3) {
                    AccountDisplayNameView(author: profile.timelineAuthor)
                        .font(.title2)
                    Text("@\(profile.handle)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let pronouns = displayedPronouns {
                        Text(pronouns)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }

                if !isCurrentProfile {
                    ProfileFollowButton(
                        isFollowing: isFollowing,
                        isUpdating: isUpdatingFollow,
                        errorGeneration: followErrorGeneration,
                        action: onFollow
                    )
                }

                profileCounts

                if let description = profile.description, !description.isEmpty {
                    RichPostTextView(
                        text: description,
                        facets: ProfileBioFacetDetector.facets(in: description),
                        textAlignment: .center
                    )
                        .frame(maxWidth: 620)
                }

                if !additionalLinks.isEmpty {
                    VStack(spacing: 5) {
                        ForEach(additionalLinks, id: \.self) { url in
                            Link(destination: url) {
                                Label(url.host() ?? url.absoluteString, systemImage: "link")
                            }
                            .font(.subheadline)
                            .lineLimit(1)
                        }
                    }
                }

                if profile.websiteURL != nil || germAvailability != nil {
                    HStack(spacing: 8) {
                        if let websiteURL = profile.websiteURL {
                            ProfileWebsiteChipView(destination: websiteURL)
                        }

                        if let germAvailability {
                            GermDMChipView(
                                destination: germAvailability.url,
                                avatarURL: germAvailability.avatarURL
                            )
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 48)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity)
            .zIndex(0)
        }
        .fullScreenCover(item: $presentedStory) { item in
            StoryViewerView(items: [item], startingAuthorID: item.id, stories: stories) { story in
                seenStore.markSeen(story)
            }
        }
    }

    private var banner: some View {
        AsyncImage(url: profile.banner) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            LinearGradient(
                colors: [Color.accentColor.opacity(0.9), Color.accentColor.opacity(0.3)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .frame(maxWidth: .infinity)
    }

    private var avatarButton: some View {
        Button {
            guard let storyItem, !storyItem.stories.isEmpty else { return }
            presentedStory = storyItem
        } label: {
            avatar
        }
        .buttonStyle(.plain)
        .accessibilityHint(storyItem?.stories.isEmpty == false ? "Opens story" : "")
    }

    private var avatar: some View {
        AsyncImage(url: profile.avatar) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .foregroundStyle(.secondary)
        }
        .frame(width: 80, height: 80)
        .background(.background, in: .circle)
        .clipShape(.circle)
        .padding(4)
        .background(.background, in: .circle)
        .overlay {
            Circle().stroke(
                hasUnseenStory ? Color.accentColor : Color(uiColor: .systemBackground),
                lineWidth: 4
            )
        }
        .accessibilityLabel("Profile picture")
    }

    private var hasUnseenStory: Bool {
        storyItem?.stories.contains { !seenStore.hasSeen($0) } == true
    }

    private var displayedPronouns: String? {
        guard let pronouns = profile.pronouns?.trimmingCharacters(in: .whitespacesAndNewlines),
              !pronouns.isEmpty else { return nil }
        return pronouns.lowercased()
    }

    private var additionalLinks: [URL] {
        links.filter { $0 != profile.websiteURL }
    }

    private var profileCounts: some View {
        HStack(spacing: 24) {
            count(profile.postsCount, label: "Posts")
            count(profile.followersCount, label: "Followers")
            count(profile.followsCount, label: "Following")
        }
        .accessibilityElement(children: .combine)
    }

    private func count(_ value: Int?, label: LocalizedStringKey) -> some View {
        VStack(spacing: 1) {
            Text((value ?? 0).formatted(.number.notation(.compactName)))
                .font(.headline.monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#endif
