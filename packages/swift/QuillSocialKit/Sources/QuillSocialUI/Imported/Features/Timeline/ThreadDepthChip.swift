#if os(iOS)
import SwiftUI

struct ThreadDepthChip: View {
    let position: Int
    let total: Int

    var body: some View {
        Text("\(position)/\(total)")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.quaternary, in: .capsule)
            .accessibilityLabel("Post \(position) of \(total) in thread")
    }
}

#endif
