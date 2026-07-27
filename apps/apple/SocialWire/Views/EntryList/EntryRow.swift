import SwiftUI

struct EntryRow: View {
    @Environment(SocialWireAppModel.self) private var appModel
    let entry: EntryListItem
    let isRead: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Group {
                if !isRead {
                    Circle()
                        .fill(Color.primary)
                        .frame(width: 8, height: 8)
                } else {
                    Color.clear
                        .frame(width: 8, height: 8)
                }
            }
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)

            thumbnail

            VStack(alignment: .leading, spacing: 4) {
                if let publicationId = entry.publicationId,
                   let publication = appModel.publication(forId: publicationId) {
                    SavedLinkPublicationChip(
                        model: SavedLinkPublicationChipModel(
                            name: publication.title,
                            faviconURL: publication.displayImageURLs.first,
                            homepageURL: nil
                        )
                    )
                }
                Text(entry.title)
                    .font(.headline)
                    .foregroundStyle(isRead ? .secondary : .primary)
                    .lineLimit(2)

                if let summary = entry.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(entry.displayPublishedAt)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var thumbnail: some View {
        let urls = ThumbnailImageURLAttempts.candidates(
            primary: entry.thumbnailUrl,
            fallback: entry.thumbnailFallbackUrl
        )
        Group {
            if urls.isEmpty {
                thumbnailPlaceholder
            } else {
                CachedRemoteImage(urls: urls, maxPixelSize: 168) {
                    thumbnailPlaceholder
                }
                .scaledToFill()
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
    }

    private var thumbnailPlaceholder: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(.tertiarySystemFill))
    }
}
