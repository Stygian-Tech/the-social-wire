import SwiftUI

struct SembleItemRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let item: SembleCollectionItem
    var isSelected = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 5) {
                Text(item.displayTitle)
                    .font(.headline)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                if let description = item.description, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 5) {
                    Text(item.contributor.label)
                    if let siteName = item.siteName, !siteName.isEmpty {
                        Text("·")
                        Text(siteName)
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                if let note = item.note, !note.text.isEmpty {
                    Label(note.text, systemImage: "note.text")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var thumbnail: some View {
        Group {
            if let image = item.image, let url = URL(string: image) {
                CachedRemoteImage(urls: [url], maxPixelSize: 120) {
                    placeholder
                }
                .scaledToFill()
            } else {
                placeholder
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(.rect(cornerRadius: 8))
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color(.tertiarySystemFill))
            .overlay {
                Image(systemName: item.cardType == "NOTE" ? "note.text" : "link")
                    .foregroundStyle(.secondary)
            }
    }
}
