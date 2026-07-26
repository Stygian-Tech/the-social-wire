import SwiftUI

struct ProfileView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var showPurgeIndexedDataConfirm = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    ViewerProfileAvatar(size: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayName)
                            .font(.headline)
                        if let handle = appModel.viewerProfile?.handle, !handle.isEmpty {
                            Text(handle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        if let did = appModel.viewerDID {
                            Text(did)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                Button {
                    dismiss()
                    appModel.openMyPublications()
                } label: {
                    Label("My Publications", systemImage: "newspaper")
                }

                NavigationLink {
                    SettingsView(showsDoneButton: false)
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }

            Section {
                Button("Log Out", role: .destructive) {
                    appModel.signOut()
                    dismiss()
                }
            }

            if SocialWireAPIEnvironment.useThinAppView {
                Section {
                    Button("Purge Indexed Data", role: .destructive) {
                        showPurgeIndexedDataConfirm = true
                    }
                } footer: {
                    Text("Removes your AppView read marks from the Social Wire index.")
                }
            }
        }
        .confirmationDialog(
            "Purge Indexed Data?",
            isPresented: $showPurgeIndexedDataConfirm,
            titleVisibility: .visible
        ) {
            Button("Purge Indexed Data", role: .destructive) {
                Task { await appModel.purgeIndexedAppViewData() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes AppView read marks for your account on the gateway.")
        }
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    dismiss()
                }
            }
        }
    }

    private var displayName: String {
        if let name = appModel.viewerProfile?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty
        {
            return name
        }
        if let handle = appModel.viewerProfile?.handle, !handle.isEmpty {
            return handle
        }
        return appModel.viewerDID ?? "Account"
    }
}
