#if os(iOS)
import SwiftUI

struct ShowMoreRepliesChip: View {
    let hiddenCount: Int
    let action: () -> Void

    @State private var feedbackTrigger = 0

    var body: some View {
        Button {
            feedbackTrigger += 1
            action()
        } label: {
            Label(
                hiddenCount == 1 ? "Show More Replies" : "Show \(hiddenCount) More Replies",
                systemImage: "ellipsis.bubble"
            )
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.quaternary, in: .capsule)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: feedbackTrigger)
    }
}

#endif
