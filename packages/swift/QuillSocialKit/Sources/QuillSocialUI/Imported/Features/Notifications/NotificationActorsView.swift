#if os(iOS)
import SwiftUI

struct NotificationActorsView: View {
    let authors: [NotificationsModel.NotificationItem.Author]
    let onSelect: (NotificationsModel.NotificationItem.Author) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(authors, id: \.did) { author in
                Button { onSelect(author) } label: {
                    HStack(spacing: 12) {
                        AsyncImage(url: author.avatar) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Image(systemName: "person.crop.circle.fill").resizable()
                        }
                        .frame(width: 40, height: 40).clipShape(.circle)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(author.displayName ?? author.handle).font(.headline)
                            Text("@\(author.handle)").font(.subheadline).foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.primary)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("People")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

#endif
