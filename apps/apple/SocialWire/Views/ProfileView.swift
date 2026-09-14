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

            if !appModel.myPublications.isEmpty {
                Section("My Publications") {
                    ForEach(appModel.myPublications) { publication in
                        Button {
                            openPublication(publication)
                        } label: {
                            HStack(spacing: 12) {
                                PublicationAvatar(publication: publication, size: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(publication.title)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                    if !publication.authorHandle.isEmpty {
                                        Text(publication.authorHandle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.thinMaterial, in: .rect(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    }
                }
            }

            Section {
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

    private func openPublication(_ publication: DiscoveredPublication) {
        Task {
            await appModel.selectPublication(publication)
            guard appModel.selectedPublication?.publicationId == publication.publicationId else { return }
            dismiss()
        }
    }
}
