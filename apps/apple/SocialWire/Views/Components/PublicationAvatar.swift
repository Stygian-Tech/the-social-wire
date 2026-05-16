import SwiftUI

struct PublicationAvatar: View {
    let publication: DiscoveredPublication
    let size: CGFloat

    var body: some View {
        Group {
            if let url = publication.displayImageURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: min(8, size / 4), style: .continuous))
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: min(8, size / 4), style: .continuous)
                .fill(.secondary.opacity(0.14))
            Text(String(publication.title.prefix(1)).uppercased())
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }
}
