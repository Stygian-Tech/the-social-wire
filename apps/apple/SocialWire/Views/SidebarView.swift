import SwiftUI

struct SidebarSectionLabel: View {
    let title: String
    let unreadCount: Int

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.medium))
            Spacer(minLength: 6)
            SidebarCountLabel(count: unreadCount)
        }
    }
}

struct SidebarCountLabel: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(count) unread")
        }
    }
}

struct PublicationSidebarRow: View {
    let publication: DiscoveredPublication
    let unreadCount: Int

    var body: some View {
        HStack(spacing: 10) {
            PublicationAvatar(publication: publication, size: 24)
            Text(publication.title)
                .lineLimit(1)
            Spacer(minLength: 6)
            SidebarCountLabel(count: unreadCount)
        }
    }
}
