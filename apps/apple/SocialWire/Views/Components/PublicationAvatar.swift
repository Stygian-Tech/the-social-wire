import SwiftUI

struct PublicationAvatar: View {
    let publication: DiscoveredPublication
    let size: CGFloat

    var body: some View {
        Group {
            if let url = publication.displayImageURL {
                CachedRemoteImage(urls: [url], maxPixelSize: max(size * 3, 72)) {
                    placeholder
                }
                .scaledToFill()
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var placeholder: some View {
        ZStack {
            Circle()
                .fill(.secondary.opacity(0.14))
            Text(String(publication.title.prefix(1)).uppercased())
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }
}
