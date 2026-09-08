import SwiftUI

struct ProfileView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var showPurgeIndexedDataConfirm = false
    @State private var showPublicReadHistoryConfirm = false

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

                NavigationLink {
                    UserInputFeedbackView()
                } label: {
                    Label("Send Feedback", systemImage: "bubble.left.and.bubble.right")
                }
            }

            if PDSReadStateSyncService.isEnabled {
                Section {
                    if appModel.readStateSync.isPDSAuthoritative {
                        Label("Public Read History Enabled", systemImage: "checkmark.circle")
                    } else {
                        Button(appModel.readStateSync.isMigrating ? "Publishing Read History…" : "Enable Public Read History") {
                            showPublicReadHistoryConfirm = true
                        }
                        .disabled(appModel.readStateSync.isMigrating || appModel.readStateSync.authority == nil)
                    }
                    if let message = appModel.readStateSync.statusMessage {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                    if appModel.readStateSync.pendingCount > 0 && !appModel.readStateSync.requiresReauthentication {
                        Button("Retry Sync") { Task { await appModel.readStateSync.flush() } }
                    }
                } header: {
                    Text("Public Read History")
                } footer: {
                    Text(PDSReadStateSyncService.publicHistoryNotice)
                }
            }

            Section {
                Button("Log Out", role: .destructive) {
                    appModel.signOut()
                    dismiss()
                }
            }

            if SocialWireAPIEnvironment.useThinAppView && !appModel.readStateSync.isPDSAuthoritative {
                Section {
                    Button("Purge Indexed Data", role: .destructive) {
                        showPurgeIndexedDataConfirm = true
                    }
                    .disabled(PDSReadStateSyncService.isEnabled && appModel.readStateSync.authority == nil)
                } footer: {
                    Text("Removes your AppView read marks from the Social Wire index.")
                }
            }
        }
        .task(id: appModel.viewerDID) { await appModel.refreshPublicReadHistoryStatus() }
        .alert("Enable Public Read History?", isPresented: $showPublicReadHistoryConfirm) {
            Button("Enable Public Read History") { Task { await appModel.enablePublicReadHistory() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(PDSReadStateSyncService.publicHistoryNotice)
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
        .platformInlineNavigationTitle()
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
