#if os(iOS)
import Feeds
import SwiftUI

struct StoryAvatarView: View {
    let item: StoryFeedItem
    let showsAccentRing: Bool
    var showsAddBadge = true

    @ScaledMetric(relativeTo: .body) private var avatarSize = 60.0
    @ScaledMetric(relativeTo: .body) private var ringWidth = 3.0
    @ScaledMetric(relativeTo: .body) private var ringPadding = 3.0
    @ScaledMetric(relativeTo: .caption) private var addBadgeSize = 22.0

    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .bottomTrailing) {
                avatar
                    .frame(width: avatarSize, height: avatarSize)
                    .clipShape(.circle)
                    .padding(ringPadding)
                    .overlay {
                        Circle()
                            .stroke(showsAccentRing ? Color.accentColor : Color.clear, lineWidth: ringWidth)
                    }

                if item.isCurrentUser && showsAddBadge {
                    Image(systemName: "plus")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .frame(width: addBadgeSize, height: addBadgeSize)
                        .background(Color.accentColor, in: .circle)
                        .overlay {
                            Circle()
                                .stroke(.background, lineWidth: 2)
                        }
                }
            }

            Text(item.isCurrentUser ? "Your Story" : item.author.displayName ?? item.author.handle)
                .font(.caption)
                .lineLimit(1)
                .frame(width: avatarSize + ringPadding * 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var avatar: some View {
        AsyncImage(url: item.author.avatarURL) { phase in
            if let image = phase.image {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(14)
                    .foregroundStyle(.secondary)
                    .background(.fill.tertiary)
            }
        }
    }

    private var accessibilityLabel: LocalizedStringResource {
        if item.isCurrentUser, item.stories.isEmpty {
            "Add to Your Story"
        } else {
            "Story by \(item.author.displayName ?? item.author.handle)"
        }
    }
}

#endif
