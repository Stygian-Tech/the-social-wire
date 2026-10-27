#if os(iOS)
import SwiftUI

struct PostComposerAttachmentsView: View {
    let attachments: [PostComposerModel.Attachment]
    let onRemove: (PostComposerModel.Attachment) -> Void
    let onEditAltText: (PostComposerModel.Attachment) -> Void
    let onMove: (UUID, UUID) -> Void
    let isGeneratingAltText: Bool
    let allowsAltTextGeneration: Bool
    let onAddAltTextToAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if allowsAltTextGeneration,
               attachments.count > 1,
               attachments.contains(where: { $0.altText.isEmpty }) {
                Button("Add Alt Text to All", systemImage: "text.badge.plus") {
                    onAddAltTextToAll()
                }
                .buttonStyle(.bordered)
                .disabled(isGeneratingAltText)

                if isGeneratingAltText {
                    ProgressView("Generating Alt Text")
                        .font(.caption)
                }
            }

            PhotoCollectionView(items: attachments, fullWidthAspectRatio: { attachment in
                guard attachment.mimeType == "image/gif" else { return nil }
                return CGFloat(max(1, attachment.width)) / CGFloat(max(1, attachment.height))
            }) { attachment in
                attachmentTile(attachment)
            }
        }
    }

    private func attachmentTile(_ attachment: PostComposerModel.Attachment) -> some View {
        Color.clear
            .overlay {
                AnimatedImageView(data: attachment.data, contentMode: attachment.mimeType == "image/gif" ? .fit : .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
            .overlay(alignment: .topTrailing) {
            Button("Remove", systemImage: "xmark") {
                onRemove(attachment)
            }
            .labelStyle(.iconOnly)
            .font(.body.weight(.bold))
            .foregroundStyle(.white)
            .padding(8)
            .background(.black.opacity(0.72), in: .circle)
            .padding(8)
            }
            .overlay(alignment: .bottomLeading) {
                Button {
                    onEditAltText(attachment)
                } label: {
                    Label(
                        attachment.altText.isEmpty ? "Add Alt Text" : "Alt Text Added",
                        systemImage: attachment.altText.isEmpty ? "text.badge.plus" : "checkmark.circle.fill"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        attachment.altText.isEmpty ? AnyShapeStyle(.black.opacity(0.78)) : AnyShapeStyle(.tint),
                        in: .capsule
                    )
                }
                .accessibilityHint(attachment.altText.isEmpty ? "Adds a description for this photo" : "Edits this photo’s description")
                .padding(8)
            }
            .frame(maxWidth: .infinity)
            .background(.fill.tertiary)
            .draggable(attachment.id.uuidString)
            .dropDestination(for: String.self) { identifiers, _ in
                guard let identifier = identifiers.first,
                      let sourceID = UUID(uuidString: identifier),
                      sourceID != attachment.id else { return false }
                onMove(sourceID, attachment.id)
                return true
            }
            .accessibilityLabel(attachment.altText.isEmpty ? "Photo without alt text" : attachment.altText)
    }
}

#endif
