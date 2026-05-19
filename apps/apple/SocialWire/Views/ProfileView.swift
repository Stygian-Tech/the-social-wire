import SwiftUI

struct ProfileView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

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

struct ViewerProfileAvatar: View {
    @Environment(SocialWireAppModel.self) private var appModel
    var size: CGFloat = 32

    var body: some View {
        Group {
            if let avatarURL = appModel.viewerProfile?.avatar.flatMap(URL.init(string:)) {
                AsyncImage(url: avatarURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Image(systemName: "person.circle.fill")
                            .resizable()
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Image(systemName: "person.circle.fill")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}
