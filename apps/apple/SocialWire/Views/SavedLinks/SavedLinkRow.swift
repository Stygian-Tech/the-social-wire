import SwiftUI

struct SavedLinkRow: View {
    @Environment(SocialWireAppModel.self) private var appModel
    let save: MergedLatrSave
    var isSelected: Bool = false

    private var publicationChip: SavedLinkPublicationChipModel? {
        appModel.resolvedSavedLinkPublicationChip(for: save)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let publicationChip {
                SavedLinkPublicationChip(model: publicationChip)
            }

            HStack(alignment: .top, spacing: 12) {
                thumbnail

                VStack(alignment: .leading, spacing: 4) {
                    Text(save.title)
                        .font(.headline)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                        .lineLimit(2)

                    if let excerpt = save.excerpt, !excerpt.isEmpty {
                        Text(excerpt)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var thumbnail: some View {
        Group {
            if let image = save.image, let url = URL(string: image) {
                CachedRemoteImage(urls: [url], maxPixelSize: 120) {
                    thumbnailPlaceholder
                }
                .scaledToFill()
            } else {
                thumbnailPlaceholder
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var thumbnailPlaceholder: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(.tertiarySystemFill))
    }

    private var subtitle: String {
        var parts: [String] = []
        if let site = save.site, !site.isEmpty {
            parts.append(site)
        } else if let host = SavedLinkEmbedURL.previewURL(for: save)?.host {
            parts.append(host)
        }
        if let author = save.author, !author.isEmpty {
            parts.append(author)
        }
        if let publishedAt = save.publishedAt, !publishedAt.isEmpty {
            parts.append(Self.formatted(publishedAt))
        }
        parts.append(Self.formatted(save.savedAt))
        return parts.joined(separator: " · ")
    }

    private static func formatted(_ raw: String) -> String {
        guard let date = DateFormatters.date(from: raw) else { return raw }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
