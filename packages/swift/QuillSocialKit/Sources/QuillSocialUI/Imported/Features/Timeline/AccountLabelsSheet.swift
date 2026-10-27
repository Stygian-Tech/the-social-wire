#if os(iOS)
import SwiftUI

struct AccountLabelsSheet: View {
    let accountName: String
    let badges: [AccountBadgeItem]
    let profileStore: AccountBadgeProfileStore

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(badges) { badge in
                HStack(spacing: 12) {
                    AsyncImage(url: profileStore.profile(for: badge.sourceDID)?.avatar) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: "bookmark")
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 36, height: 36)
                    .background(.fill.tertiary, in: .circle)
                    .clipShape(.circle)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(profileStore.displayName(for: badge.title, from: badge.sourceDID))
                        if let profile = profileStore.profile(for: badge.sourceDID) {
                            Text(profile.displayName ?? profile.handle)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(verbatim: "@\(profile.handle)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
                .task(id: badge.sourceDID) {
                    await profileStore.load(did: badge.sourceDID)
                }
            }
            .roundedNavigationTitle("Labels for \(accountName)")
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
