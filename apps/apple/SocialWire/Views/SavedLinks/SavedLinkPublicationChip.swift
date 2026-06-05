import SwiftUI

struct SavedLinkPublicationChip: View {
    let model: SavedLinkPublicationChipModel

    var body: some View {
        HStack(spacing: 6) {
            if let faviconURL = model.faviconURL {
                CachedRemoteImage(urls: [faviconURL], maxPixelSize: 32) {
                    Circle().fill(Color(.tertiarySystemFill))
                }
                .frame(width: 16, height: 16)
                .clipShape(Circle())
            }
            Text(model.name)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
    }
}
