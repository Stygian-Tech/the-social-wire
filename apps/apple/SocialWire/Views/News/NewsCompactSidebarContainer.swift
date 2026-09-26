import SwiftUI

/// A compact-width, slide-over sidebar that leaves the active feed in place.
struct NewsCompactSidebarContainer<Sidebar: View, Content: View>: View {
    @Binding var isSidebarPresented: Bool
    @GestureState private var dragTranslation: CGFloat = 0

    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            let sidebarWidth = min(geometry.size.width * 0.86, 340)

            ZStack(alignment: .leading) {
                content()
                    .allowsHitTesting(!isSidebarPresented)

                if isSidebarPresented {
                    Button {
                        withAnimation(.snappy) {
                            isSidebarPresented = false
                        }
                    } label: {
                        Color.black.opacity(0.24)
                            .ignoresSafeArea()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close Sidebar")
                    .transition(.opacity)
                }

                NavigationStack {
                    sidebar()
                }
                .frame(width: sidebarWidth)
                .frame(maxHeight: .infinity)
                .background(.regularMaterial)
                .shadow(color: .black.opacity(isSidebarPresented ? 0.22 : 0), radius: 18, x: 8)
                .offset(x: sidebarOffset(width: sidebarWidth))
                .accessibilityHidden(!isSidebarPresented)
                .gesture(isSidebarPresented ? sidebarGesture(width: sidebarWidth) : nil)

                if !isSidebarPresented {
                    Color.clear
                        .contentShape(.rect)
                        .frame(width: 24)
                        .frame(maxHeight: .infinity)
                        .gesture(sidebarGesture(width: sidebarWidth))
                        .accessibilityHidden(true)
                }
            }
            .animation(.snappy, value: isSidebarPresented)
        }
    }

    private func sidebarOffset(width: CGFloat) -> CGFloat {
        if isSidebarPresented {
            return min(0, dragTranslation)
        }
        return -width + max(0, dragTranslation)
    }

    private func sidebarGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .updating($dragTranslation) { value, state, _ in
                if isSidebarPresented || value.startLocation.x <= 24 {
                    state = value.translation.width
                }
            }
            .onEnded { value in
                if isSidebarPresented {
                    if value.translation.width < -(width * 0.2) {
                        isSidebarPresented = false
                    }
                } else if value.startLocation.x <= 24,
                          value.translation.width > width * 0.2 {
                    isSidebarPresented = true
                }
            }
    }
}
