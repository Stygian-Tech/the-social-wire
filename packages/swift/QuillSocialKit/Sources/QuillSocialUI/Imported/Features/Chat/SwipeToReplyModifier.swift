#if os(iOS)
import SwiftUI

struct SwipeToReplyModifier: ViewModifier {
    let action: () -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var feedbackTrigger = 0

    private let replyThreshold: CGFloat = 64
    private let maximumOffset: CGFloat = 80

    func body(content: Content) -> some View {
        ZStack(alignment: .leading) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .scaleEffect(replyProgress)
                .opacity(replyProgress)

            content
                .offset(x: dragOffset)
        }
        .contentShape(.rect)
        .simultaneousGesture(replyGesture)
        .sensoryFeedback(.impact(weight: .medium), trigger: feedbackTrigger)
        .accessibilityAction(named: "Reply") {
            action()
        }
    }

    private var replyProgress: CGFloat {
        min(dragOffset / replyThreshold, 1)
    }

    private var replyGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard value.translation.width > 0,
                      abs(value.translation.width) > abs(value.translation.height) else {
                    return
                }
                dragOffset = min(value.translation.width * 0.72, maximumOffset)
            }
            .onEnded { value in
                let shouldReply = value.translation.width >= replyThreshold
                    && abs(value.translation.width) > abs(value.translation.height)

                withAnimation(.snappy(duration: 0.24)) {
                    dragOffset = 0
                }

                if shouldReply {
                    feedbackTrigger += 1
                    action()
                }
            }
    }
}

extension View {
    func swipeToReply(action: @escaping () -> Void) -> some View {
        modifier(SwipeToReplyModifier(action: action))
    }
}

#endif
