#if os(iOS)
import Feeds
import Navigation
import SwiftUI

/// One pinned feed in the sidebar. Feeds open at the root of Home, the tab they belong to, so
/// choosing one from any tab lands somewhere consistent.
struct PinnedFeedRow: View {
    let feed: PinnedFeed

    @Environment(SceneRouter.self) private var router

    private var route: Route {
        .feed(feed.uri)
    }

    var body: some View {
        let isShowing = router.isShowing(route, in: .home)

        return Button {
            router.show(route, in: .home)
        } label: {
            // The feed's name is account data, so it isn't localized.
            Label(feed.name, systemImage: "square.stack")
                .font(.subheadline)
                .fontWeight(isShowing ? .semibold : .regular)
                .foregroundStyle(isShowing ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .contentShape(.rect)
        .accessibilityAddTraits(isShowing ? [.isSelected] : [])
    }
}

#endif
