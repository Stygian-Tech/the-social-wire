#if os(iOS)
import SwiftUI

struct ProfileStickyIdentityView: View {
    let profile: ProfileModel.Profile

    var body: some View {
        HStack(spacing: 8) {
            AsyncImage(url: profile.avatar) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
            .frame(width: 30, height: 30)
            .clipShape(.circle)

            VStack(alignment: .leading, spacing: 0) {
                AccountDisplayNameView(author: profile.timelineAuthor)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("@\(profile.handle)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
    }
}

#endif
