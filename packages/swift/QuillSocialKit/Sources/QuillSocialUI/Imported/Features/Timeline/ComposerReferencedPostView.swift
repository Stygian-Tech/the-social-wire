#if os(iOS)
import Feeds
import SwiftUI

struct ComposerReferencedPostView: View {
    let title: LocalizedStringResource
    let post: TimelinePost

    @State private var isExpanded: Bool

    init(title: LocalizedStringResource, post: TimelinePost, initiallyExpanded: Bool = false) {
        self.title = title
        self.post = post
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                if isExpanded {
                    TimelinePostCardView(post: post)
                } else {
                    Text(post.author.displayName ?? post.author.handle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(post.text)
                        .font(.subheadline)
                        .lineLimit(2)
                }
                Button(isExpanded ? "Show Less" : "Show Post", systemImage: isExpanded ? "chevron.up" : "chevron.down") {
                    isExpanded.toggle()
                }
                .font(.caption)
                .sensoryFeedback(.selection, trigger: isExpanded)
            }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.fill.quaternary, in: .rect(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(.separator, lineWidth: 0.5)
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

#endif
