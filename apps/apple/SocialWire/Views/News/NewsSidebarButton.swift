import SwiftUI

struct NewsSidebarButton: View {
    let action: () -> Void

    var body: some View {
        Button("Show Sidebar", systemImage: "sidebar.left", action: action)
            .labelStyle(.iconOnly)
            .accessibilityIdentifier("news-show-sidebar")
    }
}
