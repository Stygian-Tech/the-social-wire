import SwiftUI

struct ArticleListLayout<Content: View>: View {
    let notice: String?
    private let spacing: CGFloat
    private let content: Content

    init(notice: String? = nil, spacing: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.notice = notice
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: spacing) {
                if let notice {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(notice)
                }
                content
            }
            .padding()
            .frame(maxWidth: ArticleReadingWidth.feed, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}
