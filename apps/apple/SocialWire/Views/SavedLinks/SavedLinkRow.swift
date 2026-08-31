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

                    Text(save.rowSubtitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)

                    SavedTagPills(tags: save.tags)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
        .accessibilityHidden(true)
    }

    private var thumbnailPlaceholder: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(.tertiarySystemFill))
    }
}
