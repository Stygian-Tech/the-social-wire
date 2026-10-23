import SwiftUI

struct SocialAvatarView: View {
    let url: URL?
    let name: String
    var size: CGFloat = 44

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: "person.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.24)
                    .foregroundStyle(.secondary)
                    .background(.secondary.opacity(0.12))
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .accessibilityLabel(name)
    }
}
