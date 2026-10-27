#if os(iOS)
import Feeds
import SwiftUI

/// The account's pinned feeds, below the tabs in the sidebar. Only ever shown in the sidebar:
/// `tabViewSidebarFooter` hides it whenever the tabs are in a tab bar.
struct PinnedFeedsSidebarSection: View {
    @Environment(PinnedFeedsModel.self) private var pinnedFeeds

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pinned Feeds")
                .font(.footnote)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)

            if pinnedFeeds.feeds.isEmpty {
                PinnedFeedsEmptyLabel(didFail: pinnedFeeds.didFail)
            } else {
                ForEach(pinnedFeeds.feeds) { feed in
                    PinnedFeedRow(feed: feed)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }
}

#endif
