import SwiftUI

struct SettingsView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    /// When pushed from **Profile**, use the navigation back button instead of **Done**.
    var showsDoneButton: Bool = true

    var body: some View {
        Form {
            Section("Feed Display") {
                ForEach(ReaderListSource.allCases) { source in
                    let isVisible = appModel.visibleReaderListSources.contains(source)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(source.rawValue)
                            .font(.headline)
                        Toggle(
                            "Show Feed",
                            isOn: Binding(
                                get: { appModel.visibleReaderListSources.contains(source) },
                                set: { value in
                                    Task {
                                        await appModel.setFeedVisible(source, visible: value)
                                    }
                                }
                            )
                        )
                        .disabled(isVisible && appModel.visibleReaderListSources.count == 1)
                        Toggle(
                            "Show Count",
                            isOn: Binding(
                                get: { appModel.showsTopLevelFeedUnreadCount(for: source) },
                                set: { value in
                                    Task {
                                        await appModel.setFeedUnreadCountVisible(source, visible: value)
                                    }
                                }
                            )
                        )
                        .disabled(!isVisible)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Account") {
                LabeledContent("DID", value: appModel.viewerDID ?? "")
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
}
