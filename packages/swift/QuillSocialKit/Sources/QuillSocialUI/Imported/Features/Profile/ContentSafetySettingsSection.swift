#if os(iOS)
import SwiftData
import SwiftUI

struct ContentSafetySettingsSection: View {
    let showContentProvider: () -> Void
    let showModeration: () -> Void
    let showTrustedVerifiers: () -> Void

    @Query private var settings: [AppSettings]
    @State private var feedbackTrigger = 0

    var body: some View {
        Section {
            Button {
                perform(showContentProvider)
            } label: {
                Label("Content Provider", systemImage: "network")
            }

            Button {
                perform(showModeration)
            } label: {
                Label("Moderation", systemImage: "shield")
            }

            Button {
                perform(showTrustedVerifiers)
            } label: {
                HStack {
                    Label("Trusted Verifiers", systemImage: "checkmark.seal")
                    Spacer()
                    Text((settings.first?.trustedVerifierDIDs.count ?? 0).formatted())
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Content & Safety")
        } footer: {
            Text("Choose where content comes from, which moderation services apply, and whose verification attestations The Social Wire trusts.")
        }
        .sensoryFeedback(.selection, trigger: feedbackTrigger)
    }

    private func perform(_ action: () -> Void) {
        feedbackTrigger += 1
        action()
    }
}

#endif
