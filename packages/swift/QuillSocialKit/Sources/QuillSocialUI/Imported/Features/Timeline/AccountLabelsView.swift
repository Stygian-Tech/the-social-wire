#if os(iOS)
import Feeds
import SwiftUI

struct AccountLabelsView: View {
    let author: TimelineAuthor
    let moderationLabels: [TimelineLabel]

    @Environment(AppServices.self) private var services
    @State private var isShowingAllLabels = false

    private let visibleBadgeLimit = 2

    init(author: TimelineAuthor, moderationLabels: [TimelineLabel] = []) {
        self.author = author
        self.moderationLabels = moderationLabels
    }

    private var badges: [AccountBadgeItem] {
        var seen = Set<String>()
        return (author.labels + moderationLabels).compactMap {
            guard $0.value != "bot" else { return nil }
            guard seen.insert($0.id).inserted else { return nil }
            return AccountBadgeItem(
                id: "label:\($0.id)",
                title: $0.value,
                sourceDID: $0.source
            )
        }
    }

    var body: some View {
        if !badges.isEmpty {
            HStack(spacing: 5) {
                ForEach(badges.prefix(visibleBadgeLimit)) { badge in
                    AccountBadgePillView(
                        badge: badge,
                        profileStore: services.accountBadgeProfiles
                    )
                }

                if badges.count > visibleBadgeLimit {
                    Button("\(badges.count - visibleBadgeLimit) more") {
                        isShowingAllLabels = true
                    }
                    .font(.caption2)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.fill.tertiary, in: .capsule)
                    .buttonStyle(.plain)
                    .sensoryFeedback(.selection, trigger: isShowingAllLabels)
                }
            }
            .lineLimit(1)
            .sheet(isPresented: $isShowingAllLabels) {
                AccountLabelsSheet(
                    accountName: author.displayName ?? author.handle,
                    badges: badges,
                    profileStore: services.accountBadgeProfiles
                )
            }
        }
    }
}

#endif
