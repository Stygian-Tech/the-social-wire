import SwiftUI

struct SettingsView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    /// When pushed from **Profile**, use the navigation back button instead of **Done**.
    var showsDoneButton: Bool = true

    var body: some View {
        Form {
            Section("Account") {
                LabeledContent("DID", value: appModel.viewerDID ?? "")
            }

            Section {
                Text("HTTPS saves use the provider you choose. With L@tr Link, queued articles live as com.latr.saved.* records on your PDS. Other providers remember your preference until their APIs are wired in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Read Later")
            }

            Section {
                ForEach(ReadLaterServiceCatalog.options) { option in
                    readLaterOptionRow(option: option)
                        .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Settings")
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func readLaterOptionRow(option: ReadLaterServiceCatalog.Option) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(option.label)
                    .font(.subheadline.weight(.medium))

                if option.id == appModel.effectiveReadLaterServiceId {
                    Text("Selected")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                Text(option.connectedViaPDS ? "Connected" : "Not Connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)
                    )
            }

            Text(option.connectedViaPDS
                ? "Use saved HTTPS links merged from your PDS."
                : "Log in separately in \(option.label)'s site or app. In-app lists for this provider are not available yet.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                if let loginURL = option.loginURL, let loginLabel = option.loginLabel {
                    Link(loginLabel, destination: loginURL)
                        .buttonStyle(.bordered)
                }

                Button {
                    Task {
                        await appModel.selectReadLaterService(option.id)
                    }
                } label: {
                    if option.id == appModel.effectiveReadLaterServiceId {
                        Label("Using", systemImage: "checkmark")
                    } else {
                        Text("Use")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(option.id == appModel.effectiveReadLaterServiceId || appModel.isUpdatingReadLaterPreference)

                Spacer(minLength: 0)
            }
        }
        .opacity(appModel.isUpdatingReadLaterPreference ? 0.55 : 1)
    }
}
