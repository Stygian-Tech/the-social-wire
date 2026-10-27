import SwiftUI

/// A compact-width sidebar that leaves the current destination in place.
struct NewsCompactSidebarContainer<Sidebar: View, Content: View>: View {
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var isSidebarPresented: Bool
    @GestureState private var dragTranslation: CGFloat = 0

    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let content: () -> Content

    private var direction: CGFloat { layoutDirection == .rightToLeft ? -1 : 1 }

    var body: some View {
        GeometryReader { geometry in
            let sidebarWidth = min(geometry.size.width * 0.86, 340)

            ZStack(alignment: .leading) {
                content()
                    .allowsHitTesting(!isSidebarPresented)
                    .accessibilityHidden(isSidebarPresented)

                if isSidebarPresented {
                    Button {
                        isSidebarPresented = false
                    } label: {
                        Color.black.opacity(0.24)
                            .ignoresSafeArea()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close Sidebar")
                    .accessibilityIdentifier("news-sidebar-scrim")
                    .transition(.opacity)
                }

                if isSidebarPresented {
                    NavigationStack {
                        sidebar()
                    }
                    .frame(width: sidebarWidth)
                    .frame(maxHeight: .infinity)
                    .background(.regularMaterial)
                    .shadow(color: .black.opacity(isSidebarPresented ? 0.22 : 0), radius: 18, x: 8 * direction)
                    .offset(x: sidebarOffset(width: sidebarWidth))
                    .allowsHitTesting(isSidebarPresented)
                    .accessibilityHidden(!isSidebarPresented)
                    .accessibilityAddTraits(.isModal)
                    .accessibilityAction(.escape) { isSidebarPresented = false }
                    .gesture(sidebarGesture(width: sidebarWidth))
                    .transition(.move(edge: .leading))
                }
            }
            .animation(reduceMotion ? nil : .snappy, value: isSidebarPresented)
        }
    }

    private func sidebarOffset(width: CGFloat) -> CGFloat {
        direction * (isSidebarPresented ? min(0, dragTranslation) : -width)
    }

    // Only dismiss from inside the open sidebar; preserve the reader's system back gesture.
    private func sidebarGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 20)
            .updating($dragTranslation) { value, state, _ in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                state = value.translation.width * direction
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                if value.translation.width * direction < -(width * 0.2) {
                    isSidebarPresented = false
                }
            }
    }
}
