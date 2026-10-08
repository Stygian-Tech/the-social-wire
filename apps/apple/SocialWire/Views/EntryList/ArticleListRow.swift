import SwiftUI

struct ArticleListRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let model: ArticleListRowModel

    private let regularLayoutMinimumWidth: CGFloat = 440

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                compactLayout
            } else {
                ViewThatFits(in: .horizontal) {
                    regularLayout
                    compactLayout
                }
            }
        }
        .padding(12)
    }

    private var regularLayout: some View {
        HStack(alignment: .top, spacing: 14) {
            thumbnail(width: 156, height: 104)
            details
        }
        .frame(minWidth: regularLayoutMinimumWidth)
    }

    private var compactLayout: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail(width: 112, height: 84)
            details
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
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
            if let summary = model.summary, !summary.isEmpty {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(model.subtitle)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            if !model.tags.isEmpty {
                SavedTagPills(tags: model.tags)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func thumbnail(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(Color(.tertiarySystemFill))
            if model.thumbnailURLs.isEmpty {
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            } else {
                CachedRemoteImage(urls: model.thumbnailURLs, maxPixelSize: 400) {
                    Rectangle().fill(Color(.tertiarySystemFill))
                }
                .scaledToFill()
            }
        }
        .frame(width: width, height: height)
        .clipShape(.rect(cornerRadius: 10))
        .clipped()
        .accessibilityHidden(true)
    }
}
