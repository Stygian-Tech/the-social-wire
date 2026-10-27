#if os(iOS)
import SwiftUI

struct ReplyingToAvatarView: View {
    let avatarURL: URL?

    @ScaledMetric(relativeTo: .caption) private var size = 20.0

    var body: some View {
        AsyncImage(url: avatarURL) { phase in
            if let image = phase.image {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.22)
                    .foregroundStyle(.tint)
                    .background(Color.accentColor.opacity(0.16))
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .overlay {
            Circle()
                .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}

#endif
