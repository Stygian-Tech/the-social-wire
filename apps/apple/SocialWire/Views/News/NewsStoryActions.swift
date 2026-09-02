import SwiftUI

/// Keep the visible copy short while retaining explicit VoiceOver action names.
struct NewsStoryActions: View {
    let websiteURL: URL?
    let onReadInApp: () -> Void
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
        if let websiteURL {
            Link(destination: websiteURL) {
                Text("Website")
                    .frame(minHeight: 32)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Open on Website")
            .accessibilityIdentifier("story-website")
        }

        Button(action: onReadInApp) {
            Text("Read")
                .frame(minHeight: 32)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Read in App")
        .accessibilityIdentifier("story-read")

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
