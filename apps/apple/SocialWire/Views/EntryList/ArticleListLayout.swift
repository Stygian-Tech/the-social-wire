import SwiftUI

struct ArticleListLayout<Content: View>: View {
    let title: String
    let notice: String?
    private let content: Content

    init(title: String, notice: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.notice = notice
        self.content = content()
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if let notice {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(notice)
                }
                Text(title)
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                content
            }
            .padding()
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}
