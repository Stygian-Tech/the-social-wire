import SwiftUI

/// Hero treatment that opens a chapter of the feed.
///
/// At full Mac width a full-bleed banner would be over 4:1 and crop away most of a
/// normal 16:9 thumbnail, so the wide form splits the card instead: the artwork takes
/// half the measure at a near-3:2 ratio, and the headline gets the other half. Narrow
/// windows fall back to the stacked banner, where the full measure is short enough to
/// stay close to 2:1.
struct ArticleLeadCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let model: ArticleListRowModel

    /// Below this the split squeezes the headline into a column too narrow to read.
    private let sideBySideMinimumWidth: CGFloat = 640

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                stacked
            } else {
                ViewThatFits(in: .horizontal) {
                    sideBySide
                    stacked
                }
            }
        }
        .multilineTextAlignment(.leading)
    }

    private var sideBySide: some View {
        HStack(alignment: .top, spacing: 0) {
            ArticleCardImage(urls: model.thumbnailURLs)
                .frame(maxWidth: .infinity)
            details
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: sideBySideMinimumWidth)
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 0) {
            ArticleCardImage(urls: model.thumbnailURLs)
            details
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let publication = model.publication {
                SavedLinkPublicationChip(model: publication)
                    .padding(.leading, -10)
            }
            Text(model.title)
                .font(.title2.bold())
                .foregroundStyle(model.showsReadState && model.isRead ? .secondary : .primary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 4)
            if let reason = model.reason {
                Label(reason, systemImage: "sparkles")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityLabel(model.reasonAccessibilityLabel ?? reason)
            }
            if let summary = model.summary, !summary.isEmpty {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 5)
            }
            Text(model.subtitle)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            if !model.tags.isEmpty {
                SavedTagPills(tags: model.tags)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
