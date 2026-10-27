#if os(iOS)
import SwiftUI

struct AccountBadgePillView: View {
    let badge: AccountBadgeItem
    let profileStore: AccountBadgeProfileStore

    @State private var avatarURL: URL?
    @State private var displayName: String?

    var body: some View {
        HStack(spacing: 4) {
            AsyncImage(url: avatarURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "bookmark")
                    .foregroundStyle(.secondary)
            }
            .frame(width: 16, height: 16)
            .clipShape(.circle)

            Text(displayName ?? badge.title.replacingOccurrences(of: "-", with: " ").capitalized)
                .lineLimit(1)
        }
        .font(.caption2)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.fill.tertiary, in: .capsule)
        .task(id: badge.sourceDID) {
            await profileStore.load(did: badge.sourceDID)
            avatarURL = profileStore.profile(for: badge.sourceDID)?.avatar
            displayName = profileStore.displayName(for: badge.title, from: badge.sourceDID)
        }
    }
}

#endif
