import SwiftUI

struct FeedSidebarRowLabel: View {
    let title: String
    let systemImage: String
    let unreadCount: Int?

    var body: some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let unreadCount, unreadCount > 0 {
                Text(unreadCount, format: .number)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: .capsule)
                    .accessibilityLabel("\(unreadCount) unread")
            }
        }
        .readerFullWidthTapLabel()
    }
}
