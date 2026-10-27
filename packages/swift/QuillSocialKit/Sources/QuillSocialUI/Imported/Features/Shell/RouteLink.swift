#if os(iOS)
import Navigation
import SwiftUI

/// A tappable row or control that navigates to a route using the container's navigator.
struct RouteLink<Label: View>: View {
    let route: Route
    @ViewBuilder let label: Label

    @Environment(\.routeNavigator) private var navigator

    var body: some View {
        Button { navigator?(route) } label: { label }
            .buttonStyle(.plain)
            .contentShape(.rect)
            .disabled(navigator == nil)
    }
}

#endif
