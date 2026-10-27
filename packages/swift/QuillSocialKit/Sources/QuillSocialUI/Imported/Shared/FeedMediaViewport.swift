#if os(iOS)
import SwiftUI

/// The container determines media size before the image loads. Intrinsic image
/// dimensions and scaled-to-fill content must never change a feed row's bounds.
struct FeedMediaViewport<Content: View>: View {
    let aspectRatio: CGFloat
    var cornerRadius: CGFloat = 12
    @ViewBuilder let content: () -> Content

    var body: some View {
        Color.clear
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    content()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                }
            }
            .clipShape(.rect(cornerRadius: cornerRadius))
            .contentShape(.rect)
    }
}

#endif
