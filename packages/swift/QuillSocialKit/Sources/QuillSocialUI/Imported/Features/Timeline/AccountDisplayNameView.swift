#if os(iOS)
import Feeds
import SwiftData
import SwiftUI

struct AccountDisplayNameView: View {
    private static let jerryDID = "did:plc:vc7f4oafdgxsihk4cry2xpze"

    let author: TimelineAuthor

    @Environment(AppServices.self) private var services
    @Query private var settings: [AppSettings]
    @State private var isRemotelyVerified = false

    var body: some View {
        HStack(spacing: 3) {
            Text(author.displayName ?? author.handle)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            if showsVerification {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Verified")
            }

            if author.labels.contains(where: { $0.value == "bot" && !$0.isNegation }) {
                Image(systemName: "gearshape.2.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Bot Account")
            }
        }
        .fontWeight(.semibold)
        .foregroundStyle(.primary)
        .lineLimit(1)
        .layoutPriority(2)
        .task(id: verifierTaskID) {
            isRemotelyVerified = await services.remoteVerifications.isVerified(
                subjectDID: author.did,
                verifierDIDs: settings.first?.trustedVerifierDIDs ?? []
            )
        }
    }

    private var verifierTaskID: String {
        "\(author.did)|\((settings.first?.trustedVerifierDIDs ?? []).joined(separator: ","))"
    }

    private var showsBlueskyVerification: Bool {
        !author.verifications.isEmpty
            && (settings.first?.includesBlueskyVerification ?? true)
    }

    private var showsVerification: Bool {
        guard author.did != Self.jerryDID || (settings.first?.verifiesJerry ?? true) else {
            return false
        }
        return showsBlueskyVerification || isRemotelyVerified
    }
}

#endif
