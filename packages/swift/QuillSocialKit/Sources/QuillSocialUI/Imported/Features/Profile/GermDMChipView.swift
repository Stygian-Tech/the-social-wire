#if os(iOS)
import SwiftUI

struct GermDMChipView: View {
    let destination: URL
    let avatarURL: URL?

    var body: some View {
        Link(destination: destination) {
            HStack(spacing: 6) {
                AsyncImage(url: avatarURL) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    Image(systemName: "globe.americas.fill")
                        .resizable()
                        .scaledToFit()
                        .padding(4)
                        .foregroundStyle(.white)
                        .background(.green)
                }
                .frame(width: 24, height: 24)
                .clipShape(.circle)

                Text("Germ DM")
                    .font(.subheadline.weight(.semibold))
            }
        }
        .buttonStyle(ThemeChipButtonStyle())
        .accessibilityHint("Opens Germ DM")
    }
}

#endif
