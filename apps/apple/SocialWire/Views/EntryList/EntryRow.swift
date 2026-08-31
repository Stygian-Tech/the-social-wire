import SwiftUI

struct EntryRow: View {
    @Environment(SocialWireAppModel.self) private var appModel
    let entry: EntryListItem
    let isRead: Bool
    let showsReadState: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if showsReadState {
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
            }

            thumbnail

            VStack(alignment: .leading, spacing: 4) {
                if let wire = entry.wireMetadata {
                    SavedLinkPublicationChip(
                        model: SavedLinkPublicationChipModel(
                            name: wire.source.displayName,
                            faviconURL: PublicationSiteFavicon.url(for: wire.source.domain)
                                .flatMap(URL.init(string:)),
                            homepageURL: URL(string: "https://\(wire.source.domain)")
                        )
                    )
                } else if let publicationId = entry.publicationId,
                   let publication = appModel.publication(forId: publicationId) {
                    SavedLinkPublicationChip(
                        model: SavedLinkPublicationChipModel(
                            name: publication.title,
                            faviconURL: publication.displayImageURLs.first,
                            homepageURL: nil
                        )
                    )
                }

                if let sourceDomain = entry.sourceDomain {
                    Label(sourceDomain, systemImage: "globe")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(entry.title)
                    .font(.headline)
                    .foregroundStyle(showsReadState && isRead ? .secondary : .primary)
                    .lineLimit(2)

                if let reasons = entry.wireMetadata?.reasonLabels, !reasons.isEmpty {
                    ForEach(reasons, id: \.self) { reason in
                        Label(reason, systemImage: "sparkles")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
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
