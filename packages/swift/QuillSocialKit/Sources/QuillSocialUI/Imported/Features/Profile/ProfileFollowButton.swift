#if os(iOS)
import SwiftUI

struct ProfileFollowButton: View {
    let isFollowing: Bool
    let isUpdating: Bool
    let errorGeneration: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(
                isFollowing ? "Following" : "Follow",
                systemImage: isFollowing ? "person.badge.checkmark" : "person.badge.plus"
            )
            .frame(minWidth: 108)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .tint(isFollowing ? .secondary : .accentColor)
        .disabled(isUpdating)
        .sensoryFeedback(.selection, trigger: isFollowing)
        .sensoryFeedback(.error, trigger: errorGeneration)
    }
}

#endif
