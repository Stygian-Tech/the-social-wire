import SwiftUI

/// Middle tier of the feed rhythm: an image-on-top card sized to sit in a
/// responsive multi-column band between the lead story and the compact rows.
struct ArticleGridCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let model: ArticleListRowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ArticleCardImage(urls: model.thumbnailURLs)
            VStack(alignment: .leading, spacing: ArticleCardMetrics.spacing) {
                if let publication = model.publication {
                    SavedLinkPublicationChip(model: publication)
                        .padding(.leading, -10)
                }
                Text(model.title)
                    .font(.headline)
                    .foregroundStyle(model.showsReadState && model.isRead ? .secondary : .primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
                if let reason = model.reason {
                    Label(reason, systemImage: "sparkles")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityLabel(model.reasonAccessibilityLabel ?? reason)
                }
                Text(model.subtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                if !model.tags.isEmpty {
                    SavedTagPills(tags: model.tags)
                }
                // Rows in the band share one height; pin the text to the top of it.
                Spacer(minLength: 0)
            }
            .padding(ArticleCardMetrics.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .multilineTextAlignment(.leading)
    }
}
