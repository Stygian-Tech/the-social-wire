import SwiftUI

/// Keep the visible copy short while retaining explicit VoiceOver action names.
struct NewsStoryActions: View {
    let onOpenStory: () -> Void
    var onHide: (() -> Void)?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                actions
            }
            .fixedSize(horizontal: true, vertical: false)

            VStack(alignment: .leading, spacing: 8) {
                actions
            }
        }
        .font(.subheadline.weight(.semibold))
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var actions: some View {
        Button(action: onOpenStory) {
            Text("Open Story")
                .frame(minHeight: 32)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityLabel("Open Story")
        .accessibilityHint("Opens the publisher's website unless this is an RSS story set to use the native reader.")
        .accessibilityIdentifier("story-open")

        if let onHide {
            Button(role: .destructive, action: onHide) {
                Label("Hide Story", systemImage: "eye.slash")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("story-hide")
        }
    }
}
