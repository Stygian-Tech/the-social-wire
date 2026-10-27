#if os(iOS)
import ATProtoCore
import Navigation
import SwiftUI

struct TimelineAvatarView: View {
    let avatarURL: URL?
    var actor: String?
    var isLiveStreaming = false

    @ScaledMetric(relativeTo: .body) private var size = 44.0
    @Environment(\.routeNavigator) private var navigator

    var body: some View {
        Button {
            guard let actor, let identifier = try? ActorIdentifier(actor) else { return }
            navigator?(.profile(identifier))
        } label: {
            ZStack(alignment: .bottomTrailing) {
                AsyncImage(url: avatarURL) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "person.fill")
                            .resizable()
                            .scaledToFit()
                            .padding(size * 0.24)
                            .foregroundStyle(.secondary)
                            .background(.fill.tertiary)
                    }
                }
                .frame(width: size, height: size)
                .clipShape(.circle)

                if isLiveStreaming {
                    Circle()
                        .fill(.red)
                        .frame(width: size * 0.25, height: size * 0.25)
                        .overlay { Circle().stroke(.background, lineWidth: 2) }
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(actor == nil || navigator == nil)
        .frame(width: size, height: size)
        .accessibilityLabel(actor.map { "Open @\($0) Profile" } ?? "Profile Picture")
    }
}

#endif
