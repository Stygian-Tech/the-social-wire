#if os(iOS)
import SwiftUI

extension EnvironmentValues {
    @Entry var videoPlaybackBounds: CGRect = .zero
}

private struct VideoPlaybackViewport: ViewModifier {
    @State private var bounds: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { bounds = $0 }
            .environment(\.videoPlaybackBounds, bounds)
    }
}

extension View {
    func videoPlaybackViewport() -> some View {
        modifier(VideoPlaybackViewport())
    }
}

#endif
