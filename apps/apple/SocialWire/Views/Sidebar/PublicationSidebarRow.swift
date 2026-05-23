import SwiftUI

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
        .padding(.vertical, 4)
    }
}
