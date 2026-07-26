import SwiftUI

struct ViewerProfileAvatar: View {
    @Environment(SocialWireAppModel.self) private var appModel
    var size: CGFloat = 32

    var body: some View {
        Group {
            if let avatarURL = appModel.viewerProfile?.avatar.flatMap(URL.init(string:)) {
                AsyncImage(url: avatarURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Image(systemName: "person.circle.fill")
                            .resizable()
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Image(systemName: "person.circle.fill")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}
