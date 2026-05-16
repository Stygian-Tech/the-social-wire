import SwiftUI

struct SettingsView: View {
    @Environment(SocialWireAppModel.self) private var appModel

    var body: some View {
        Form {
            Section("Account") {
                LabeledContent("DID", value: appModel.viewerDID ?? "")
                Button("Sign Out", role: .destructive) {
                    appModel.signOut()
                }
            }

            Section("Read Later") {
                LabeledContent("Provider", value: "L@tr Link")
                Text("Saved links are stored with com.latr.saved.* records on your PDS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
    }
}
