#if os(iOS)
import Feeds
import SwiftUI

struct PostLabelsView: View {
    let labels: [TimelineLabel]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(labels) { label in
                    Label(label.value.replacingOccurrences(of: "-", with: " ").capitalized, systemImage: "checkmark.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.fill.tertiary, in: .capsule)
                        .accessibilityHint(Text("Applied by labeler \(label.source)"))
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}

#endif
