#if os(iOS)
import SwiftUI

struct ProfileAttributionChip: View {
    let title: LocalizedStringResource
    let avatarURL: URL?
    let handle: String

    var body: some View {
        HStack(spacing: 6) {
            ReplyingToAvatarView(avatarURL: avatarURL)
                .padding(.vertical, 2)

            HStack(spacing: 3) {
                Text(title)
                    .fixedSize(horizontal: true, vertical: false)
                Text(verbatim: "@\(handle)")
                    .bold()
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
            }
        }
        .font(.caption)
        .foregroundStyle(.tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.accentColor.opacity(0.12), in: .capsule)
        .overlay {
            Capsule()
                .stroke(Color.accentColor.opacity(0.24), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(Text(title)) @\(handle)"))
    }
}

#endif
