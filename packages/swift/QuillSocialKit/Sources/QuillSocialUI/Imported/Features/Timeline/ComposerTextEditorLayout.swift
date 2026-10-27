#if os(iOS)
import SwiftUI

/// Give the native editor a concrete viewport, measured independently from its scroll content.
struct ComposerTextEditorLayout<Editor: View>: View {
    let text: String
    let maximumHeight: CGFloat
    @ViewBuilder let editor: () -> Editor
    @State private var contentHeight: CGFloat = 120

    var body: some View {
        editor()
            .font(.body)
            .frame(height: min(maximumHeight, max(120, contentHeight)))
            .background(alignment: .topLeading) {
                Text(text + "\n")
                    .font(.body)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        ceil(geometry.size.height)
                    } action: { height in
                        contentHeight = height
                    }
            }
    }
}
#endif
