import SwiftUI

struct ReaderFeedEmptyStateView: View {
    let isUnreadFilter: Bool
    let action: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(description)
        } actions: {
            Button(actionTitle, action: action)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String {
        isUnreadFilter ? "You're All Caught Up" : "No Articles Yet"
    }

    private var systemImage: String {
        isUnreadFilter ? "checkmark.circle" : "newspaper"
    }

    private var description: String {
        isUnreadFilter
            ? "There are no unread articles in this feed."
            : "New articles from this feed will appear here."
    }

    private var actionTitle: String {
        isUnreadFilter ? "Show All" : "Refresh"
    }
}
