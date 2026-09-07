import SwiftUI

struct EntryRow: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let entry: EntryListItem
    let isRead: Bool
    let showsReadState: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            thumbnail

            VStack(alignment: .leading, spacing: 6) {
                if let wire = entry.wireMetadata {
                    SavedLinkPublicationChip(
                        model: SavedLinkPublicationChipModel(
                            name: wire.source.displayName,
                            faviconURL: PublicationSiteFavicon.url(for: wire.source.domain)
                                .flatMap(URL.init(string:)),
                            homepageURL: URL(string: "https://\(wire.source.domain)")
                        )
                    )
                    .padding(.leading, -10)
                } else if let publicationId = entry.publicationId,
                          let publication = appModel.publication(forId: publicationId) {
                    SavedLinkPublicationChip(
                        model: SavedLinkPublicationChipModel(
                            name: publication.title,
                            faviconURL: publication.displayImageURLs.first,
                            homepageURL: nil
                        )
                    )
                    .padding(.leading, -10)
                }
                Text(entry.title)
                    .font(.headline)
                    .foregroundStyle(showsReadState && isRead ? .secondary : .primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)

                if let wire = entry.wireMetadata, let reason = wire.primaryReasonLabel {
                    Label(reason, systemImage: "sparkles")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityLabel(wire.reasonLabels.joined(separator: ", "))
                }

                if let summary = entry.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(entry.displayPublishedAt)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
    }

    @ViewBuilder
    private var thumbnail: some View {
        let urls = ThumbnailImageURLAttempts.candidates(
            primary: entry.thumbnailUrl,
            fallback: entry.thumbnailFallbackUrl
        )
        ZStack {
            Rectangle()
                .fill(Color(.tertiarySystemFill))
            if urls.isEmpty {
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            } else {
                CachedRemoteImage(urls: urls, maxPixelSize: 400) {
                    thumbnailPlaceholder
                }
                .scaledToFill()
            }
        }
        .frame(width: 156, height: 104)
        .clipShape(.rect(cornerRadius: 10))
        .clipped()
        .accessibilityHidden(true)
    }

    private var thumbnailPlaceholder: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(.tertiarySystemFill))
    }
}
